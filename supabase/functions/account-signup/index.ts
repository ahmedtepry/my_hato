// Creates a customer account without sending any confirmation email (Supabase's built-in mailer
// is limited to a few emails per hour, which blocked real sign-ups with "too many attempts").
// POST { email, password, full_name, username?, phone? } (no session needed).
// The account is created already confirmed; the app then signs in normally. Ordering, repairs and
// reviews stay locked until a team member verifies the account (customers.review_status).
// Username/phone uniqueness and format are enforced by the database trigger on the new user.
import { corsHeaders, json, serviceClient } from "../_shared/util.ts";

// Leaked-password check (Have I Been Pwned, k-anonymity: only the first 5 characters of the SHA-1 leave this server). Fails OPEN.
async function isLeaked(password: string): Promise<boolean> {
  try {
    const buf = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(password));
    const hex = [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
    const res = await fetch(`https://api.pwnedpasswords.com/range/${hex.slice(0, 5)}`, { headers: { "Add-Padding": "true" }, signal: AbortSignal.timeout(3000) });
    if (!res.ok) return false;
    const suffix = hex.slice(5);
    for (const line of (await res.text()).split("\n")) {
      const [h, c] = line.trim().split(":");
      if (h === suffix && Number(c) > 0) return true;
    }
  } catch (_) { /* fail open */ }
  return false;
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  const fullName = String(body.full_name ?? "").trim();
  const username = body.username ? String(body.username).trim().toLowerCase() : undefined;
  const phone = body.phone ? String(body.phone).trim() : undefined;
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 254) return json(req, 400, { error: "invalid_email" });
  if (password.length < 8 || password.length > 72) return json(req, 400, { error: "invalid_password" });
  if (fullName.length < 2 || fullName.length > 100) return json(req, 400, { error: "invalid_name" });

  const db = serviceClient();
  // anti-spam: at most 10 sign-ups per hour from one address
  const ip = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  try {
    const { data: ok } = await db.rpc("hit_rate_limit", { p_bucket: "signup_ip", p_key_hash: await sha256Hex("ip:" + ip), p_window_seconds: 3600, p_max: 10 });
    if (ok === false) return json(req, 429, { error: "RATE_LIMITED" });
  } catch (_) { /* never block sign-up because of the limiter itself */ }
  if (await isLeaked(password)) return json(req, 400, { error: "invalid_password", reason: "compromised_password" });

  const { error } = await db.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: fullName, ...(username ? { username } : {}), ...(phone ? { phone } : {}) },
  });
  if (error) {
    const m = `${error.code ?? ""} ${error.message ?? ""}`.toLowerCase();
    if (m.includes("email_exists") || m.includes("already") || m.includes("registered")) return json(req, 409, { error: "ALREADY_REGISTERED" });
    if (m.includes("weak_password")) return json(req, 400, { error: "invalid_password" });
    return json(req, 400, { error: "FAILED" });
  }
  return json(req, 200, { ok: true });
});
