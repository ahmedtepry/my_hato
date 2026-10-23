// Changes the signed-in customer's email. The current password is required as proof that the
// person at the keyboard owns the account (checked with a throw-away client, so the caller's
// session is untouched). No confirmation email is sent (the built-in mailer is heavily limited);
// the password check is the confirmation. A database trigger on auth.users syncs profile/customer.
// An account that has no email yet (e.g. phone-only) adds one without a password check: there is no
// password to check, and the session itself is the proof.
// POST { new_email, password } with the user's JWT.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { callerClient, corsHeaders, json, requireEnv, serviceClient } from "../_shared/util.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  const { data: u } = await callerClient(req).auth.getUser();
  const user = u?.user;
  if (!user) return json(req, 401, { error: "unauthorized" });

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const newEmail = String(body.new_email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(newEmail) || newEmail.length > 254) return json(req, 400, { error: "invalid_email" });
  const hasEmail = !!user.email;
  if (hasEmail && (!password || password.length > 200)) return json(req, 400, { error: "invalid_password" });
  if (hasEmail && newEmail === user.email!.toLowerCase()) return json(req, 400, { error: "SAME_EMAIL" });

  if (hasEmail) {
    const probe = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: pErr } = await probe.auth.signInWithPassword({ email: user.email!, password });
    if (pErr) {
      const rl = pErr.status === 429 || `${pErr.code}`.includes("rate_limit");
      return json(req, rl ? 429 : 401, { error: rl ? "RATE_LIMITED" : "WRONG_PASSWORD" });
    }

  }

  const { error } = await serviceClient().auth.admin.updateUserById(user.id, { email: newEmail, email_confirm: true });
  if (error) {
    const m = `${error.code ?? ""} ${error.message ?? ""}`.toLowerCase();
    if (m.includes("email_exists") || m.includes("already") || m.includes("registered")) return json(req, 409, { error: "EMAIL_TAKEN" });
    return json(req, 400, { error: "FAILED" });
  }
  return json(req, 200, { ok: true, email: newEmail });
});
