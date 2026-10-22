// Admin payment operations (permissions re-checked in SQL as the caller):
//   verify        – checks Paymob credentials (API key -> auth token + merchant profile) — settings.manage
//   set_online    – enable/disable online payments in the app (only after verify succeeded) — settings.manage
//   admin_card_setup / admin_card_remove – the admin's own card, separate from everything else — settings.manage
//   refund        – refund a succeeded Paymob transaction — orders.manage (+ refunds enabled)
// Nothing here marks money as received: statuses change only from HMAC-verified Paymob callbacks.
import { callerClient, corsHeaders, json, serviceClient } from "../_shared/util.ts";
import { checkoutUrl, integrationIds, missingPaymobSecrets, paymob, PaymobError } from "../_shared/paymob.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });
  const caller = callerClient(req);
  const { data: auth } = await caller.auth.getUser();
  const user = auth?.user;
  if (!user) return json(req, 401, { error: "unauthorized" });

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const db = serviceClient();
  const can = async (perm: string) => (await caller.rpc("has_permission", { p_permission: perm })).data === true;

  try {
    switch (body.action) {
      case "verify": {
        if (!(await can("settings.manage"))) return json(req, 403, { error: "forbidden" });
        const missing = [...missingPaymobSecrets(), ...(Deno.env.get("PAYMOB_API_KEY") ? [] : ["PAYMOB_API_KEY"])];
        if (missing.length) {
          await db.rpc("payment_record_provider_check", { p_ok: false, p_account_id: null, p_status: { missing_secrets: missing } });
          return json(req, 200, { ok: false, missing_secrets: missing });
        }
        // validates the API key with Paymob and returns the merchant profile
        // deno-lint-ignore no-explicit-any
        const tok: any = await paymob("/api/auth/tokens", { api_key: Deno.env.get("PAYMOB_API_KEY") }, "none");
        const profile = tok?.profile ?? {};
        const status = {
          api_key_valid: !!tok?.token, profile_id: profile.id ?? null, company: profile.company_name ?? null,
          country: profile.country ?? "EGY", integration_ids: integrationIds(),
          admin_card_integration: integrationIds("PAYMOB_VERIFICATION_INTEGRATION_ID")[0] ?? null,
          livemode: !String(Deno.env.get("PAYMOB_SECRET_KEY")).includes("test"),
        };
        const ok = status.api_key_valid && status.integration_ids.length > 0;
        await db.rpc("payment_record_provider_check", { p_ok: ok, p_account_id: profile.id ? String(profile.id) : null, p_status: status });
        return json(req, 200, { ok, status });
      }
      case "set_online": {
        const { error } = await caller.rpc("staff_set_online_payments", { p_enabled: body.enabled === true });
        if (error) {
          const nc = error.message.includes("PAYMENTS_NOT_CONFIGURED");
          return json(req, nc ? 409 : 403, { error: nc ? "PAYMENTS_NOT_CONFIGURED" : "forbidden" });
        }
        return json(req, 200, { ok: true });
      }
      case "admin_card_setup": {
        if (!(await can("settings.manage"))) return json(req, 403, { error: "forbidden" });
        const integ = integrationIds("PAYMOB_VERIFICATION_INTEGRATION_ID");
        if (missingPaymobSecrets().length || !integ.length) return json(req, 503, { error: "PROVIDER_NOT_CONFIGURED" });
        const amount = parseInt(Deno.env.get("PAYMOB_ADMIN_CARD_VERIFY_AMOUNT") ?? "100", 10); // verification integration (no capture)
        const intent = await paymob<{ id: string; intention_order_id: number | string; client_secret: string }>("/v1/intention/", {
          amount, currency: "EGP", payment_methods: integ,
          items: [{ name: "Admin card verification", amount, quantity: 1 }],
          billing_data: { first_name: "My", last_name: "Hato Admin", email: user.email ?? "admin@myhato.app", phone_number: "+20000000000",
            apartment: "NA", floor: "NA", street: "NA", building: "NA", city: "NA", state: "NA", country: "EG" },
          special_reference: `admin_card_${crypto.randomUUID()}`,
          notification_url: `${Deno.env.get("SUPABASE_URL")}/functions/v1/payments-webhook`,
          redirection_url: Deno.env.get("ADMIN_DASHBOARD_URL") ?? undefined,
          extras: { purpose: "admin_card", actor: user.id },
        });
        await db.rpc("payment_set_admin_pending", { p_provider_order_id: String(intent.intention_order_id), p_actor: user.id });
        return json(req, 200, { checkout_url: checkoutUrl(intent.client_secret) });
      }
      case "admin_card_remove": {
        if (!(await can("settings.manage"))) return json(req, 403, { error: "forbidden" });
        await db.rpc("payment_set_admin_card", { p_customer: null, p_pm: null, p_brand: null, p_last4: null,
          p_exp_month: null, p_exp_year: null, p_status: "removed", p_actor: user.id });
        return json(req, 200, { ok: true });
      }
      case "refund": {
        const amount = Number(body.amount_minor);
        if (!Number.isInteger(amount)) return json(req, 400, { error: "INVALID_AMOUNT" });
        const { data: chk, error } = await caller.rpc("staff_refund_check", { p_payment_id: body.payment_id, p_amount_minor: amount });
        if (error) {
          const code = ["REFUNDS_DISABLED", "NOT_REFUNDABLE", "INVALID_AMOUNT", "NOT_FOUND"].find((c) => error.message.includes(c)) ?? "forbidden";
          return json(req, code === "forbidden" ? 403 : 409, { error: code });
        }
        // double-click / retry guard: one refund request per (payment, already-refunded, amount)
        const { error: lockErr } = await db.from("payment_events").insert({
          provider: "paymob", provider_event_id: `refund_request:${body.payment_id}:${chk.refunded_minor}:${amount}`,
          event_type: "REFUND_REQUEST", payment_id: body.payment_id, result: `by:${user.id}`,
        });
        if (lockErr) return json(req, 409, { error: "REFUND_IN_PROGRESS" });
        // deno-lint-ignore no-explicit-any
        const r: any = await paymob("/api/acceptance/void_refund/refund", { transaction_id: Number(chk.provider_transaction_id), amount_cents: amount });
        return json(req, 200, { ok: true, provider_transaction_id: r?.id ?? null, provider_success: r?.success ?? null, pending: r?.pending ?? null });
      }
      default:
        return json(req, 400, { error: "unknown_action" });
    }
  } catch (e) {
    console.log(JSON.stringify({ fn: "payments-admin", action: body?.action, error: e instanceof PaymobError ? e.code : "internal" }));
    return json(req, e instanceof PaymobError ? (e.status === 503 ? 503 : 502) : 500, { error: e instanceof PaymobError ? e.code : "internal_error" });
  }
});
