// Creates a customer account without sending any confirmation email (Supabase's built-in mailer
// is limited to a few emails per hour, which blocked real sign-ups with "too many attempts").
// POST { email, password, full_name, username?, phone? } (no session needed).
// The account is created already confirmed; the app then signs in normally. Ordering, repairs and
// reviews stay locked until a team member verifies the account (customers.review_status).
// Username/phone uniqueness and format are enforced by the database trigger on the new user.
import { corsHeaders, json, serviceClient } from "../_shared/util.ts";

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

  const { error } = await serviceClient().auth.admin.createUser({
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
