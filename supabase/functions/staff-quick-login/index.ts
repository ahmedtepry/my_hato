// Quick sign-in for the Windows team app (face or Windows Hello fingerprint). No password and no JWT: the caller proves
// itself with the random device key(s) the app stored after an earlier password sign-in, plus a face print (face mode).
// The database (quick_login_check) decides; on success this returns a one-time token the app trades for a normal session.
//   { keys: string[], print: number[], model: string }   -> face
//   { keys: [string] }                                    -> fingerprint (that device must have it turned on)
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (_req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json; charset=utf-8" } });
const corsHeaders = (_req: Request) => cors;
const clientIp = (req: Request) => req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
const serviceClient = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });
  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  if (body.ping === true) return json(req, 200, { ok: true, warm: true });
  const keys = Array.isArray(body.keys) ? body.keys.filter((k: unknown) => typeof k === "string" && k.length >= 32 && k.length <= 200).slice(0, 20) : [];
  if (keys.length === 0) return json(req, 400, { error: "invalid_input" });
  let print: string | null = null;
  if (body.print != null) {
    if (!Array.isArray(body.print) || body.print.length < 64 || body.print.length > 1024 || !body.print.every((v: unknown) => typeof v === "number" && Number.isFinite(v))) {
      return json(req, 400, { error: "invalid_input" });
    }
    print = `[${body.print.join(",")}]`;
  }
  const db = serviceClient();
  const { data, error } = await db.rpc("quick_login_check", { p_keys: keys, p_print: print, p_model: String(body.model ?? "sface-2021dec") });
  if (error) {
    console.error("quick_login_check", clientIp(req), error.message);
    return json(req, 500, { ok: false, error: "server" });
  }
  // deno-lint-ignore no-explicit-any
  const r = data as any;
  if (!r?.ok) return json(req, 200, { ok: false, error: r?.error ?? "NO_MATCH" });
  const link = await db.auth.admin.generateLink({ type: "magiclink", email: r.email });
  const tokenHash = link.data?.properties?.hashed_token;
  if (link.error || !tokenHash) {
    console.error("generateLink", link.error?.message);
    return json(req, 500, { ok: false, error: "server" });
  }
  // app 158+ (v: 2): open the session here, next to the auth server, so the app does not need another round trip
  if (body.v !== 2) return json(req, 200, { ok: true, token_hash: tokenHash, name: r.name });
  const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const v = await anon.auth.verifyOtp({ type: "magiclink", token_hash: tokenHash });
  if (v.error || !v.data?.session) return json(req, 200, { ok: true, token_hash: tokenHash, name: r.name });
  return json(req, 200, { ok: true, session: v.data.session, name: r.name });
});
