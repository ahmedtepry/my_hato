// Run: node --experimental-strip-types --test supabase/functions/tests/templates.test.ts
// (also runs under `deno test`)
import { test } from "node:test";
import assert from "node:assert/strict";

// minimal Deno shim when running under Node
(globalThis as any).Deno ??= { env: { get: (k: string) => (k === "ADMIN_DASHBOARD_URL" ? "https://admin.example" : undefined) } };

const { egp, escapeHtml, timingSafeEqual, sha256Hex } = await import("../_shared/format.ts");
const { renderOrderNew, renderRepairNew, renderRepairResponse } = await import("../_shared/email_templates.ts");

test("egp formats piasters without float errors", () => {
  assert.equal(egp(20000), "200 ج.م");
  assert.equal(egp(4500000), "45,000 ج.م");
  assert.equal(egp(79950), "799.50 ج.م");
  assert.equal(egp(null), "—");
});

test("escapeHtml neutralises injection in customer fields", () => {
  assert.equal(escapeHtml(`<script>alert("x")</script>`), "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;");
});

test("timingSafeEqual", () => {
  assert.ok(timingSafeEqual("abc", "abc"));
  assert.ok(!timingSafeEqual("abc", "abd"));
  assert.ok(!timingSafeEqual("abc", "abcd"));
});

test("sha256Hex", async () => {
  assert.equal(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

test("order email contains all required fields and escapes names", () => {
  const r = renderOrderNew({
    id: "o1", reference: "MH-261022-1000", created_at: "2026-10-22T10:00:00Z",
    customer_name: "<b>Ahmed</b>", customer_phone: "+201011111111", customer_email: "a@x.com",
    fulfillment: "pickup", payment_method: "pay_at_branch", branch: { name_ar: "الفرع الرئيسي", address_ar: "القاهرة" },
    subtotal_minor: 4659800, discount_minor: 339900, delivery_fee_minor: 0, total_minor: 4659800,
    items: [{ name_ar: "آيفون 15", sku: "IPH15-128", quantity: 1, unit_price_minor: 4500000, line_total_minor: 4500000 }],
  });
  for (const s of ["MH-261022-1000", "IPH15-128", "46,598 ج.م", "الفرع الرئيسي", "+201011111111", "https://admin.example/#/orders/o1"]) {
    assert.ok(r.html.includes(s), `missing ${s}`);
  }
  assert.ok(!r.html.includes("<b>Ahmed</b>"));
  assert.match(r.subject, /طلب جديد/);
});

test("repair emails (new + customer response)", () => {
  const base = { id: "r1", reference: "MY-HATO75", created_at: "2026-10-22T10:00:00Z", device_brand: "Apple", device_model: "iPhone 13",
    contact_name: "Ahmed", contact_phone: "+201011111111", problem_description: "شاشة مكسورة", photo_count: 2,
    pickup_address: { governorate: "القاهرة", city: "مدينة نصر", street: "عباس العقاد" } };
  const n = renderRepairNew(base);
  assert.ok(n.subject.includes("MY-HATO75") && n.html.includes("مدينة نصر") && n.html.includes("شاشة مكسورة"));
  const a = renderRepairResponse({ ...base, decision: "approved", via: "customer_app", quote: { amount_minor: 20000 } });
  assert.ok(a.subject.includes("وافق") && a.html.includes("200 ج.م"));
});
