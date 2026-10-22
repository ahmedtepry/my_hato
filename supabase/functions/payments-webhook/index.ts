// Paymob callback endpoint (notification_url of every intention).
// The ONLY place where payment success/failure/refund and saved-card tokens are recorded.
// - verifies ?hmac= (HMAC-SHA512 with PAYMOB_HMAC_SECRET) before touching anything
// - idempotent: each (transaction id + state) is applied at most once
// - amount + currency re-checked against the order before it is marked paid
import { json, serviceClient } from "../_shared/util.ts";
import { verifyPaymobHmac } from "../_shared/paymob_hmac.ts";

Deno.serve(async (req) => {
  // Paymob may also hit the URL with a GET "response callback" — nothing is recorded from it.
  if (req.method === "GET") return json(req, 200, { ok: true });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  const hmac = new URL(req.url).searchParams.get("hmac");
  // deno-lint-ignore no-explicit-any
  let payload: any;
  try { payload = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  const type = payload?.type === "TOKEN" ? "TOKEN" : "TRANSACTION";
  const obj = payload?.obj ?? {};
  if (!(await verifyPaymobHmac(obj, type, hmac, Deno.env.get("PAYMOB_HMAC_SECRET") ?? ""))) {
    return json(req, 401, { error: "invalid_hmac" });
  }

  const db = serviceClient();
  try {
    if (type === "TOKEN") {
      const { error } = await db.rpc("paymob_apply_card_token", {
        p_provider_order_id: String(obj.order_id), p_token: String(obj.token), p_masked_pan: obj.masked_pan ?? null,
        p_card_subtype: obj.card_subtype ?? null,
        p_exp_month: obj.expiry_month ? parseInt(obj.expiry_month, 10) : null, p_exp_year: obj.expiry_year ? parseInt(obj.expiry_year, 10) : null,
      });
      if (error) throw new Error("db_token_failed");
    } else {
      const eventId = `paymob:${obj.id}:${obj.success}:${obj.pending}:${obj.is_voided}:${obj.is_refunded}:${obj.is_refund ?? false}`;
      const { error } = await db.rpc("paymob_apply_transaction", {
        p_event_id: eventId, p_provider_order_id: String(obj.order?.id ?? obj.order), p_transaction_id: String(obj.id),
        p_success: obj.success === true, p_pending: obj.pending === true, p_is_voided: obj.is_voided === true || obj.is_void === true,
        p_is_refund: obj.is_refund === true, p_amount_cents: Number(obj.amount_cents), p_currency: obj.currency ?? null,
        p_source_type: obj.source_data?.type ?? null, p_source_subtype: obj.source_data?.sub_type ?? null,
        p_pan: obj.source_data?.pan ?? null, p_error: obj.data?.txn_response_code ?? obj.data?.message ?? null,
      });
      if (error) throw new Error("db_apply_failed");
    }
  } catch (_e) {
    console.log(JSON.stringify({ fn: "payments-webhook", type, id: obj?.id, error: "processing_failed" }));
    return json(req, 500, { error: "processing_failed" }); // Paymob retries; processing is idempotent
  }
  return json(req, 200, { received: true });
});
