import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Receives the SMS the office phone gets when money arrives in a wallet (sent by an SMS-forwarder app).
// The caller proves itself with the secret key (header x-hook-token, or ?token=). Only the key's hash is stored in the database.
// This function never moves money: it only records what the SMS says. No JWT: the forwarder app cannot sign in.

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });
  const url = new URL(req.url);
  const token = (req.headers.get("x-hook-token") ?? url.searchParams.get("token") ?? "").trim();
  if (!token || token.length > 200) return reply(401, { error: "unauthorized" });
  const raw = await req.text();
  if (raw.length > 4000) return reply(413, { error: "too_large" });
  let from = "", text = "";
  const ct = req.headers.get("content-type") ?? "";
  try {
    if (ct.includes("application/json")) {
      // deno-lint-ignore no-explicit-any
      const b: any = JSON.parse(raw);
      from = String(b.from ?? b.sender ?? b.address ?? b.number ?? "");
      text = String(b.text ?? b.message ?? b.body ?? b.content ?? b.sms ?? "");
    } else {
      const p = new URLSearchParams(raw);
      from = p.get("from") ?? p.get("sender") ?? p.get("address") ?? "";
      text = p.get("text") ?? p.get("message") ?? p.get("body") ?? p.get("content") ?? raw;
    }
  } catch {
    return reply(400, { error: "invalid_body" });
  }
  text = text.trim();
  if (!text) return reply(400, { error: "empty" });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await sb.rpc("_wallet_inbox_ingest", { p_hash: await sha256Hex(token), p_from: from.slice(0, 40), p_text: text.slice(0, 1000) });
  if (error) return reply(500, { error: "failed" });
  if (data?.ok !== true) return reply(data?.reason === "unauthorized" ? 401 : 400, { error: data?.reason ?? "failed" });
  return reply(200, { ok: true });
});
