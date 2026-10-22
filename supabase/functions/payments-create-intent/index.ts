// Creates (or reuses) a Paymob payment intention for an ONLINE order of the signed-in customer and
// returns the Unified Checkout URL. Amount always comes from the order row in the database.
import { callerClient, corsHeaders, json, serviceClient } from "../_shared/util.ts";
import { checkoutUrl, integrationIds, missingPaymobSecrets, paymob, PaymobError } from "../_shared/paymob.ts";

const ERR_MAP: Record<string, number> = {
  ONLINE_PAYMENTS_DISABLED: 409, NOT_FOUND: 404, NOT_ONLINE_ORDER: 400, ORDER_CANCELLED: 409, ALREADY_PAID: 409, PAYMENT_IN_PROGRESS: 409,
};
const INTENT_TTL_SECONDS = 3600;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });
  if (missingPaymobSecrets().length) return json(req, 503, { error: "PROVIDER_NOT_CONFIGURED" });

  const { data: auth } = await callerClient(req).auth.getUser();
  const user = auth?.user;
  if (!user) return json(req, 401, { error: "unauthorized" });

  let body: { order_id?: string; save_card?: boolean };
  try { body = await req.json(); } catch { return json(req, 400, { error: "invalid_json" }); }
  if (!/^[0-9a-f-]{36}$/i.test(String(body.order_id ?? ""))) return json(req, 400, { error: "invalid_order" });
  const saveCard = body.save_card === true; // explicit opt-in

  const db = serviceClient();
  const { data: prep, error: prepErr } = await db.rpc("payment_prepare", { p_user_id: user.id, p_order_id: body.order_id, p_save_card: saveCard });
  if (prepErr) {
    const code = Object.keys(ERR_MAP).find((k) => prepErr.message.includes(k)) ?? "payment_prepare_failed";
    return json(req, ERR_MAP[code] ?? 500, { error: code });
  }
  if (prep.reused) return json(req, 200, { payment_id: prep.payment_id, checkout_url: checkoutUrl(prep.reuse_client_secret) });

  const name = String(prep.customer?.full_name ?? "").trim() || "My Hatō customer";
  const [first, ...rest] = name.split(/\s+/);
  const email = prep.customer?.email || user.email || "customer@myhato.app";
  const phone = prep.customer?.phone || (user.phone ? `+${String(user.phone).replace(/^\+/, "")}` : "+20000000000");

  try {
    const intent = await paymob<{ id: string; intention_order_id: number | string; client_secret: string }>("/v1/intention/", {
      amount: prep.amount_minor,                       // piasters ("cents")
      currency: String(prep.currency).toUpperCase(),   // EGP
      payment_methods: integrationIds(),               // card / Apple Pay / wallets ... as enabled on YOUR Paymob account
      items: [{ name: `My Hatō order ${prep.reference}`, amount: prep.amount_minor, quantity: 1, description: prep.reference }],
      billing_data: {
        first_name: first || "NA", last_name: rest.join(" ") || "NA", email, phone_number: phone,
        apartment: "NA", floor: "NA", street: "NA", building: "NA", city: "NA", state: "NA", country: "EG",
      },
      customer: { first_name: first || "NA", last_name: rest.join(" ") || "NA", email },
      special_reference: prep.payment_id,             // unique per attempt
      expiration: INTENT_TTL_SECONDS,
      notification_url: `${Deno.env.get("SUPABASE_URL")}/functions/v1/payments-webhook`,
      redirection_url: Deno.env.get("PAYMOB_REDIRECT_URL") ?? "com.myhato.app://payment-return",
      extras: { payment_id: prep.payment_id, order_id: body.order_id, save_card: saveCard },
      ...(Array.isArray(prep.card_tokens) && prep.card_tokens.length ? { card_tokens: prep.card_tokens } : {}),
    });
    await db.rpc("payment_attach_intent", {
      p_payment_id: prep.payment_id, p_intent_id: String(intent.id), p_provider_order_id: String(intent.intention_order_id),
      p_client_secret: intent.client_secret, p_expires_at: new Date(Date.now() + INTENT_TTL_SECONDS * 1000).toISOString(),
    });
    return json(req, 200, { payment_id: prep.payment_id, checkout_url: checkoutUrl(intent.client_secret) });
  } catch (e) {
    console.log(JSON.stringify({ fn: "payments-create-intent", error: e instanceof PaymobError ? e.code : "internal" }));
    return json(req, e instanceof PaymobError ? (e.status === 503 ? 503 : 502) : 500, { error: e instanceof PaymobError ? e.code : "internal_error" });
  }
});
