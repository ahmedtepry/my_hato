// "استعلام عن طلب صيانة" for guests.
// Step 1 {action:"start", reference}: sends a 6-digit code by SMS to the verified phone on the repair.
// Step 2 {action:"verify", reference, code}: returns ONLY non-sensitive status data
// (no address, IMEI, photos, phone or internal notes).
// Responses never reveal whether a reference exists (anti-enumeration).
// Abuse protection: per-IP and per-reference rate limits + optional Cloudflare Turnstile.
import { clientIp, corsHeaders, json, serviceClient, sha256Hex, timingSafeEqual } from "../_shared/util.ts";

const CODE_TTL_SECONDS = 120;
const MAX_ATTEMPTS = 5;
const REF_RE = /^MY-HATO\d{1,10}$/;

async function verifyTurnstile(token: string | undefined, ip: string): Promise<boolean> {
  const secret = Deno.env.get("TURNSTILE_SECRET_KEY");
  if (!secret) return true; // not configured => rely on rate limits (documented)
  if (!token) return false;
  const res = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    body: new URLSearchParams({ secret, response: token, remoteip: ip }),
  });
  const body = await res.json().catch(() => ({}));
  return body?.success === true;
}

async function sendSms(to: string, text: string): Promise<boolean> {
  const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const token = Deno.env.get("TWILIO_AUTH_TOKEN");
  const from = Deno.env.get("TWILIO_FROM");
  if (!sid || !token || !from) throw new Error("SMS_NOT_CONFIGURED");
  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(`${sid}:${token}`), "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ To: to, From: from, Body: text }),
  });
  return res.ok;
}

function randomCode(): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return n.toString().padStart(6, "0");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  const db = serviceClient();
  const pepper = Deno.env.get("LOOKUP_CODE_PEPPER") ?? "";
  if (pepper.length < 16) return json(req, 503, { error: "LOOKUP_NOT_CONFIGURED" });

  let body: { action?: string; reference?: string; code?: string; captcha?: string };
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const reference = String(body.reference ?? "").trim().toUpperCase();
  if (!REF_RE.test(reference)) return json(req, 400, { error: "invalid_reference" });

  const ip = clientIp(req);
  const ipHash = await sha256Hex(pepper + ip);
  const refHash = await sha256Hex(pepper + reference);

  const limit = async (bucket: string, key: string, windowS: number, max: number) => {
    const { data } = await db.rpc("hit_rate_limit", { p_bucket: bucket, p_key_hash: key, p_window_seconds: windowS, p_max: max });
    return data === true;
  };

  if (body.action === "start") {
    if (!(await limit("lookup_start_ip", ipHash, 3600, 10)) || !(await limit("lookup_start_ref", refHash, 3600, 3))) {
      return json(req, 429, { error: "rate_limited" });
    }
    if (!(await verifyTurnstile(body.captcha, ip))) return json(req, 403, { error: "captcha_failed" });

    const generic = { ok: true, message_ar: "لو الرقم صحيح، هيوصلك كود على الموبايل المسجّل.", message_en: "If the reference is valid, a code was sent to the registered phone.", expires_in: CODE_TTL_SECONDS };
    const { data: rows } = await db.rpc("repair_contact_for_lookup", { p_reference: reference });
    const target = rows?.[0];
    if (!target) return json(req, 200, generic);

    const code = randomCode();
    await db.from("repair_lookup_challenges").insert({
      repair_id: target.repair_id,
      code_hash: await sha256Hex(pepper + target.repair_id + code),
      expires_at: new Date(Date.now() + CODE_TTL_SECONDS * 1000).toISOString(),
      requester_ip_hash: ipHash,
    });
    try {
      await sendSms(target.verified_phone, `My Hatō: كود الاستعلام عن طلب ${reference} هو ${code} (صالح دقيقتين)`);
    } catch (err) {
      if (String(err).includes("SMS_NOT_CONFIGURED")) return json(req, 503, { error: "SMS_NOT_CONFIGURED" });
      return json(req, 502, { error: "sms_failed" });
    }
    return json(req, 200, generic);
  }

  if (body.action === "verify") {
    if (!(await limit("lookup_verify_ip", ipHash, 3600, 30))) return json(req, 429, { error: "rate_limited" });
    const code = String(body.code ?? "");
    if (!/^\d{6}$/.test(code)) return json(req, 400, { error: "invalid_code" });

    const { data: rows } = await db.rpc("repair_contact_for_lookup", { p_reference: reference });
    const target = rows?.[0];
    if (!target) return json(req, 400, { error: "invalid_or_expired_code" });

    const { data: ch } = await db.from("repair_lookup_challenges")
      .select("id, code_hash, attempts, expires_at, consumed_at")
      .eq("repair_id", target.repair_id).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (!ch || ch.consumed_at || new Date(ch.expires_at) < new Date() || ch.attempts >= MAX_ATTEMPTS) {
      return json(req, 400, { error: "invalid_or_expired_code" });
    }
    await db.from("repair_lookup_challenges").update({ attempts: ch.attempts + 1 }).eq("id", ch.id);
    const ok = timingSafeEqual(ch.code_hash, await sha256Hex(pepper + target.repair_id + code));
    if (!ok) return json(req, 400, { error: "invalid_or_expired_code" });

    await db.from("repair_lookup_challenges").update({ consumed_at: new Date().toISOString() }).eq("id", ch.id);
    const { data: view } = await db.rpc("guest_repair_public_view", { p_reference: reference });
    return json(req, 200, { ok: true, repair: view });
  }

  return json(req, 400, { error: "unknown_action" });
});
