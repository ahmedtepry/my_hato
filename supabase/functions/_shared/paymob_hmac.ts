// Paymob callback HMAC verification (pure WebCrypto — unit-testable in Node and Deno).
// Paymob sends ?hmac=<hex> on callbacks. HMAC-SHA512 (HMAC secret from the Paymob dashboard)
// over the concatenated values of fixed, lexicographically ordered fields.
// Docs: developers.paymob.com → Webhook (Callbacks) & HMAC.

// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;

const get = (o: Obj, path: string): unknown => path.split(".").reduce<unknown>((v, k) => (v == null ? v : (v as Obj)[k]), o);

/** Paymob stringification: booleans lowercase, null/undefined empty, numbers as-is. */
const str = (v: unknown): string => (v === null || v === undefined ? "" : typeof v === "boolean" ? (v ? "true" : "false") : String(v));

export const TRANSACTION_FIELDS = [
  "amount_cents", "created_at", "currency", "error_occured", "has_parent_transaction", "id", "integration_id",
  "is_3d_secure", "is_auth", "is_capture", "is_refunded", "is_standalone_payment", "is_voided", "order.id",
  "owner", "pending", "source_data.pan", "source_data.sub_type", "source_data.type", "success",
];
export const TOKEN_FIELDS = ["card_subtype", "created_at", "email", "id", "masked_pan", "merchant_id", "order_id", "token"];

export function hmacString(obj: Obj, type: "TRANSACTION" | "TOKEN"): string {
  return (type === "TOKEN" ? TOKEN_FIELDS : TRANSACTION_FIELDS).map((f) => str(get(obj, f))).join("");
}

export async function hmacSha512Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function verifyPaymobHmac(obj: Obj, type: "TRANSACTION" | "TOKEN", received: string | null, secret: string): Promise<boolean> {
  if (!received || !secret || !obj) return false;
  const expected = await hmacSha512Hex(secret, hmacString(obj, type));
  const a = expected.toLowerCase(), b = received.toLowerCase();
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
