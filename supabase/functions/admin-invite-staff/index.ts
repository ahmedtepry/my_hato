// Owner-only: invite a staff member by email and assign a role.
// Public sign-up NEVER grants staff roles; this is the only provisioning path.
import { callerClient, corsHeaders, json, serviceClient } from "../_shared/util.ts";

const ROLES = ["owner", "manager", "sales", "technician", "support"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  const caller = callerClient(req);
  const { data: userRes } = await caller.auth.getUser();
  if (!userRes?.user) return json(req, 401, { error: "unauthorized" });
  const { data: allowed } = await caller.rpc("has_permission", { p_permission: "staff.manage" });
  if (allowed !== true) return json(req, 403, { error: "forbidden" });

  let body: { email?: string; role?: string; full_name?: string };
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const email = String(body.email ?? "").trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !ROLES.includes(String(body.role))) {
    return json(req, 400, { error: "invalid_input" });
  }

  const admin = serviceClient();
  const redirectTo = Deno.env.get("ADMIN_DASHBOARD_URL");
  const { data: invited, error } = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo, data: { full_name: body.full_name ?? null },
  });
  let userId = invited?.user?.id;
  if (error) {
    // already registered -> look up existing user id
    const { data: list } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
    userId = list?.users.find((u) => u.email?.toLowerCase() === email)?.id;
    if (!userId) return json(req, 400, { error: "invite_failed" });
  }
  // grant via the audited RPC as the caller (permission re-checked in SQL)
  const { error: gErr } = await caller.rpc("staff_set_role", { p_user_id: userId, p_role: body.role, p_grant: true });
  if (gErr) return json(req, 403, { error: "grant_failed" });
  return json(req, 200, { ok: true, user_id: userId });
});
