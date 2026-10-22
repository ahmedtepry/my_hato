// node --experimental-strip-types --test supabase/functions/tests/paymob_hmac.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
const { verifyPaymobHmac, hmacString, hmacSha512Hex } = await import("../_shared/paymob_hmac.ts");

const secret = "PAYMOB_HMAC_TEST";
const txn = {
  id: 192036465, pending: false, amount_cents: 465980, success: true, is_auth: false, is_capture: false,
  is_standalone_payment: true, is_voided: false, is_refunded: false, is_3d_secure: true, integration_id: 4097558,
  has_parent_transaction: false, owner: 302852, currency: "EGP", error_occured: false, created_at: "2026-10-22T14:00:00.123456",
  order: { id: 217503754 }, source_data: { pan: "2346", type: "card", sub_type: "MasterCard" },
};
const expectedStr = "4659802026-10-22T14:00:00.123456EGPfalsefalse1920364654097558truefalsefalsefalsetruefalse217503754302852false2346MasterCardcardtrue";
const sig = createHmac("sha512", secret).update(expectedStr).digest("hex");

test("transaction concatenation follows Paymob field order", () => assert.equal(hmacString(txn, "TRANSACTION"), expectedStr));
test("sha512 matches Node crypto", async () => assert.equal(await hmacSha512Hex(secret, expectedStr), sig));
test("valid hmac accepted (case-insensitive)", async () => {
  assert.ok(await verifyPaymobHmac(txn, "TRANSACTION", sig, secret));
  assert.ok(await verifyPaymobHmac(txn, "TRANSACTION", sig.toUpperCase(), secret));
});
test("tampered amount / success flag rejected", async () => {
  assert.equal(await verifyPaymobHmac({ ...txn, amount_cents: 100 }, "TRANSACTION", sig, secret), false);
  assert.equal(await verifyPaymobHmac({ ...txn, success: false }, "TRANSACTION", sig, secret), false);
});
test("missing hmac / wrong secret rejected", async () => {
  assert.equal(await verifyPaymobHmac(txn, "TRANSACTION", null, secret), false);
  assert.equal(await verifyPaymobHmac(txn, "TRANSACTION", sig, "other"), false);
});
test("token callback fields", async () => {
  const tok = { card_subtype: "Visa", created_at: "2026-10-22T14:00:00", email: "a@b.c", id: 55, masked_pan: "xxxx-xxxx-xxxx-4242", merchant_id: 302852, order_id: 217503754, token: "abc" };
  const s = createHmac("sha512", secret).update("Visa2026-10-22T14:00:00a@b.c55xxxx-xxxx-xxxx-4242302852217503754abc").digest("hex");
  assert.ok(await verifyPaymobHmac(tok, "TOKEN", s, secret));
});
