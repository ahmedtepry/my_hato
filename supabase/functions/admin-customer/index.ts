// Support tools for customer accounts (permission: support.manage — owner, manager, support).
//   reset_password { user_id, password } – sets a new password when a customer asks support
//                                          ("forgot password" in the app sends customers to WhatsApp).
//   activate       { user_id }           – accepts a new account waiting for approval: confirms it in Auth
//                                          so the customer can sign in, then marks it approved (welcome
//                                          notification + audit via staff_mark_account_approved).
// Every action is written to the audit log with the staff member who did it.
import { callerClient, corsHeaders, json, serviceClient } from "../_shared/util.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  const caller = callerClient(req);
  const { data: auth } = await caller.auth.getUser();
  const staff = auth?.user;
  if (!staff) return json(req, 401, { error: "unauthorized" });
  const { data: allowed } = await caller.rpc("has_permission", { p_permission: "support.manage" });
  if (allowed !== true) return json(req, 403, { error: "forbidden" });

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const userId = String(body.user_id ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(userId)) return json(req, 400, { error: "invalid_user" });
  const db = serviceClient();

  if (body.action === "reset_password") {
    const password = String(body.password ?? "");
    if (password.length < 8 || password.length > 72 || !/[A-Za-z؀-ۿ]/.test(password) || !/\d/.test(password)) {
      return json(req, 400, { error: "WEAK_PASSWORD" });
    }
    // staff accounts are managed separately; this tool is for customers only
    const { data: roles } = await db.from("user_roles").select("role").eq("user_id", userId).limit(1);
    if (roles && roles.length) return json(req, 403, { error: "STAFF_ACCOUNT" });
    const { data: cust } = await db.from("customers").select("customer_code").eq("user_id", userId).maybeSingle();
    if (!cust) return json(req, 404, { error: "NOT_FOUND" });

    const { error } = await db.auth.admin.updateUserById(userId, { password });
    if (error) return json(req, 400, { error: "UPDATE_FAILED" });
    await db.from("audit_logs").insert({
      actor_id: staff.id, action: "customer.password_reset", entity_type: "customer", entity_id: cust.customer_code,
      details: { user_id: userId, via: "admin-customer" },
    });
    return json(req, 200, { ok: true, customer_code: cust.customer_code });
  }
  if (body.action === "activate") {
    const { data: roles } = await db.from("user_roles").select("role").eq("user_id", userId).limit(1);
    if (roles && roles.length) return json(req, 403, { error: "STAFF_ACCOUNT" });
    const { data: cust } = await db.from("customers").select("customer_code").eq("user_id", userId).maybeSingle();
    if (!cust) return json(req, 404, { error: "NOT_FOUND" });
    const { error } = await db.auth.admin.updateUserById(userId, { email_confirm: true, ban_duration: "none" });
    if (error) return json(req, 400, { error: "UPDATE_FAILED" });
    // as the staff member, so the audit log and reviewed_by name them
    const { error: markErr } = await caller.rpc("staff_mark_account_approved", { p_user_id: userId });
    if (markErr) return json(req, 400, { error: "MARK_FAILED" });
    return json(req, 200, { ok: true, customer_code: cust.customer_code });
  }
  return json(req, 400, { error: "unknown_action" });
});
