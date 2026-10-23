// Lets a new customer sign in right after creating an account (no waiting for activation).
// POST { identifier, password } (no session needed). The password is checked by login_email_for()
// (rate limited, never reveals whether an account exists); only then the account is confirmed in
// Auth so normal sign-in works. Ordering / repairs / reviews stay locked until a team member
// approves the account (customers.review_status), and rejected accounts are not opened.
import { callerClient, corsHeaders, json, serviceClient } from "../_shared/util.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const identifier = String(body.identifier ?? "").trim();
  const password = String(body.password ?? "");
  if (!identifier || !password || identifier.length > 254 || password.length > 200) return json(req, 400, { error: "invalid_input" });

  const { data: email, error: lErr } = await callerClient(req).rpc("login_email_for", { p_identifier: identifier, p_password: password });
  if (lErr) return json(req, 429, { error: String(lErr.message ?? "").includes("RATE_LIMITED") ? "RATE_LIMITED" : "FAILED" });
  if (!email) return json(req, 401, { error: "invalid_credentials" });

  const db = serviceClient();
  const { data: cust } = await db.from("customers").select("user_id, review_status").eq("email", String(email).toLowerCase()).maybeSingle();
  if (!cust) return json(req, 404, { error: "NOT_FOUND" });
  if (cust.review_status === "rejected") return json(req, 403, { error: "REJECTED" });

  const { error } = await db.auth.admin.updateUserById(cust.user_id, { email_confirm: true });
  if (error) return json(req, 400, { error: "FAILED" });
  return json(req, 200, { ok: true, email, review_status: cust.review_status });
});
