import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { callerClient, corsHeaders, json, requireEnv, serviceClient } from "../_shared/util.ts";

// Changes the customer's contact phone only after the account password is re-entered.
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });
  const { data: u } = await callerClient(req).auth.getUser();
  const user = u?.user;
  if (!user) return json(req, 401, { error: "unauthorized" });
  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const phone = String(body.phone ?? "").trim();
  const password = String(body.password ?? "");
  if (phone !== "" && !/^\+20(10|11|12|15)\d{8}$/.test(phone)) return json(req, 400, { error: "INVALID_PHONE" });
  if (!password || password.length > 200 || !user.email) return json(req, 400, { error: "invalid_password" });
  const probe = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error: pErr } = await probe.auth.signInWithPassword({ email: user.email, password });
  if (pErr) {
    const rl = pErr.status === 429 || `${pErr.code}`.includes("rate_limit");
    return json(req, rl ? 429 : 401, { error: rl ? "RATE_LIMITED" : "WRONG_PASSWORD" });
  }
  const { error } = await serviceClient().from("profiles").update({ contact_phone: phone === "" ? null : phone }).eq("id", user.id);
  // a number that belongs to someone else gets the same plain answer as any other failure
  if (error) return json(req, 400, { error: "FAILED" });
  return json(req, 200, { ok: true });
});
