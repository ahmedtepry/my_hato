// Customer saved cards (Paymob card tokens): remove or set default.
// Removing deletes our reference to the token; a Paymob token is unusable without our secret key,
// so once removed it can never be offered or charged again from My Hatō.
import { callerClient, corsHeaders, json, serviceClient } from "../_shared/util.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });
  const { data: auth } = await callerClient(req).auth.getUser();
  const user = auth?.user;
  if (!user) return json(req, 401, { error: "unauthorized" });

  let body: { action?: string; method_id?: string };
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  if (!/^[0-9a-f-]{36}$/i.test(String(body.method_id ?? ""))) return json(req, 400, { error: "invalid_method" });
  const db = serviceClient();

  if (body.action === "set_default") {
    const { error } = await db.rpc("payment_set_default_method", { p_user_id: user.id, p_method_id: body.method_id });
    return error ? json(req, 404, { error: "not_found" }) : json(req, 200, { ok: true });
  }
  if (body.action === "remove") {
    const { error } = await db.rpc("payment_remove_method", { p_user_id: user.id, p_method_id: body.method_id });
    if (error) return json(req, error.message.includes("NOT_FOUND") ? 404 : 500, { error: error.message.includes("NOT_FOUND") ? "not_found" : "remove_failed" });
    return json(req, 200, { ok: true });
  }
  return json(req, 400, { error: "unknown_action" });
});
