// Team accounts (permission: staff.manage — owner only).
//   create         { login, password, role, full_name?, phone? } – new team account; signs in with the login
//                  name the owner chose (any language, spaces OK) + password; ready immediately.
//   suspend        { user_id, suspended }                       – stop / restore a member's access instantly.
//   reset_password { user_id, password }                          – new password for a team member.
// Roles are always granted through the audited SQL functions, as the calling owner.
import { callerClient, corsHeaders, json, serviceClient } from "../_shared/util.ts";

const ROLES = ["owner", "manager", "sales", "technician", "support"];

function egMobile(p: string): string | null {
  let d = p.replace(/[٠-٩]/g, (c) => String(c.charCodeAt(0) - 0x0660)).replace(/\D/g, "");
  if (d.startsWith("0020")) d = d.slice(2);
  if (d.startsWith("01") && d.length === 11) d = "2" + d;
  return /^201[0125]\d{8}$/.test(d) ? "+" + d : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  const caller = callerClient(req);
  const { data: auth } = await caller.auth.getUser();
  if (!auth?.user) return json(req, 401, { error: "unauthorized" });
  const { data: allowed } = await caller.rpc("has_permission", { p_permission: "staff.manage" });
  if (allowed !== true) return json(req, 403, { error: "forbidden" });

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const db = serviceClient();

  if (body.action === "create") {
    const fullName = String(body.full_name ?? "").trim().slice(0, 80);
    const login = String(body.login ?? body.username ?? "").trim().replace(/\s+/g, " ");
    const password = String(body.password ?? "");
    const role = String(body.role ?? "");
    const phoneRaw = String(body.phone ?? "").trim();
    const phone = phoneRaw ? egMobile(phoneRaw) : null;
    if (!ROLES.includes(role)) return json(req, 400, { error: "INVALID_INPUT" });
    if (login.length < 2 || login.length > 40 || login.includes("@")) return json(req, 400, { error: "INVALID_USERNAME" });
    if (phoneRaw && !phone) return json(req, 400, { error: "INVALID_PHONE" });
    if (password.length < 6 || password.length > 72) return json(req, 400, { error: "WEAK_PASSWORD" });

    const { data: free } = await caller.rpc("staff_login_available", { p_login: login });
    if (free !== true) return json(req, 409, { error: "USERNAME_TAKEN" });
    if (phone) {
      const { data: ptaken } = await db.from("customers").select("user_id").eq("phone", phone).limit(1);
      if (ptaken && ptaken.length) return json(req, 409, { error: "PHONE_TAKEN" });
    }

    const { data: created, error } = await db.auth.admin.createUser({
      email: `t${crypto.randomUUID().replace(/-/g, "").slice(0, 16)}@team.myhato.app`,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName || login, ...(phone ? { phone } : {}) },
    });
    if (error || !created?.user) return json(req, 400, { error: error?.message?.includes("assword") ? "WEAK_PASSWORD" : "CREATE_FAILED" });
    const userId = created.user.id;
    const { error: gErr } = await caller.rpc("staff_assign_role", { p_user_id: userId, p_role: role });
    const { error: lErr } = gErr ? { error: gErr } : await caller.rpc("staff_register_login", { p_user_id: userId, p_login: login });
    if (gErr || lErr) {
      await db.auth.admin.deleteUser(userId); // never leave a half-made team account behind
      return json(req, 400, { error: String((lErr ?? gErr)?.message ?? "GRANT_FAILED") });
    }
    return json(req, 200, { ok: true, user_id: userId, login });
  }

  if (body.action === "suspend") {
    const userId = String(body.user_id ?? "");
    const suspended = body.suspended === true;
    if (!/^[0-9a-f-]{36}$/i.test(userId)) return json(req, 400, { error: "invalid_user" });
    // permissions stop right away (SQL); Auth also refuses new sign-ins / token refresh while suspended
    const { error: sErr } = await caller.rpc("staff_set_suspended", { p_user_id: userId, p_suspended: suspended });
    if (sErr) return json(req, 400, { error: String(sErr.message ?? "FAILED") });
    const { error } = await db.auth.admin.updateUserById(userId, { ban_duration: suspended ? "876000h" : "none" });
    if (error) return json(req, 400, { error: "UPDATE_FAILED" });
    return json(req, 200, { ok: true });
  }

  if (body.action === "reset_password") {
    const userId = String(body.user_id ?? "");
    const password = String(body.password ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(userId)) return json(req, 400, { error: "invalid_user" });
    if (password.length < 6 || password.length > 72) return json(req, 400, { error: "WEAK_PASSWORD" });
    const { data: roles } = await db.from("user_roles").select("role").eq("user_id", userId).limit(1);
    if (!roles || !roles.length) return json(req, 404, { error: "NOT_FOUND" });
    const { error } = await db.auth.admin.updateUserById(userId, { password });
    if (error) return json(req, 400, { error: "UPDATE_FAILED" });
    await db.from("audit_logs").insert({
      actor_id: auth.user.id, action: "staff.password_reset", entity_type: "user", entity_id: userId, details: { via: "admin-staff" },
    });
    return json(req, 200, { ok: true });
  }
  return json(req, 400, { error: "unknown_action" });
});
