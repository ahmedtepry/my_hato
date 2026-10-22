# Online payments (Paymob, Egypt): setup and go-live

## Why Paymob

My Hatō is an Egyptian business, so payments go through **Paymob**, an Egyptian payment gateway licensed under the Central Bank of Egypt.

- Customers pay in **EGP**.
- Paymob settles to the merchant's **Egyptian bank account** (EGP).
- Customers enter card details only on **Paymob's Unified Checkout page**. The app opens that page in an in-app browser tab, and the admin dashboard opens it in a new tab. My Hatō never sees, sends or stores a card number or CVV.

Payment methods appear only if they are **enabled on your Paymob account** (one *Integration ID* per method):

| Method | Notes |
|---|---|
| Visa / Mastercard / Meeza cards | Standard online card integration (3-D Secure) |
| Apple Pay | Ask Paymob to enable it. Shown on Apple devices only. |
| Mobile wallets (Vodafone Cash, Etisalat Cash, Orange Cash, WE Pay…) | "Mobile Wallet" integration |
| Google Pay | **Confirm with Paymob** that it is available for your account. It shows only if Paymob enables it. |
| Saved cards | Paymob card tokens, saved only if the customer ticks «احفظ البطاقة». Each payment still needs the customer's confirmation on Paymob's page. Saved cards are never charged automatically. |

## How the money moves

`Customer → Paymob (charge, EGP) → Paymob merchant balance → settlement → Egyptian bank account registered with Paymob`

- The IBAN, account holder and bank name in **إعدادات استقبال المدفوعات** are **for reference only**. All three are empty by default.
- Paymob pays out to the bank account registered **on your Paymob merchant account**. You set that account up with Paymob (onboarding or support), not in this app.
- An order is shown as **paid** only after **all** of these are true:
  1. Paymob's callback arrives with a valid **HMAC-SHA512** signature.
  2. `success = true` and `pending = false`.
  3. The amount and currency match the order (EGP, in piasters).
- "Paid" does not mean "money in your bank". Payouts follow Paymob's settlement schedule.
- Nothing in the code fakes a successful payment or a bank transfer.

## What you need to give (do not share it in chat; put it in Supabase secrets)

1. **Open a Paymob merchant account** at https://accept.paymob.com and complete KYC: commercial register, tax card, bank account.
2. In the **Paymob dashboard**:
   - **Settings → Account info**: copy the **API Key**, **Secret Key**, **Public Key** and **HMAC secret**.
   - **Developers → Payment Integrations**: note the **Integration ID** of each method you want (card, wallet, Apple Pay…).
   - Ask Paymob for a **card verification / tokenization integration** (no capture) for the admin card. This step is optional.
   - Set the **Transaction processed callback** and **Transaction response callback** of each integration to:
     `https://efdomvgypdkpqubkkjwm.supabase.co/functions/v1/payments-webhook`
3. **Supabase → Project Settings → Edge Functions → Secrets**:

   | Secret | Value |
   |---|---|
   | `PAYMOB_SECRET_KEY` | Secret key (`egy_sk_live_…`; use `egy_sk_test_…` while testing) |
   | `PAYMOB_PUBLIC_KEY` | Public key (`egy_pk_…`). Only used to build the checkout URL; safe to expose. |
   | `PAYMOB_HMAC_SECRET` | HMAC secret |
   | `PAYMOB_INTEGRATION_IDS` | Comma-separated, e.g. `4512345,4512346` (card, wallet, Apple Pay…) |
   | `PAYMOB_API_KEY` | API key (used only by the admin "Verify" button) |
   | `PAYMOB_VERIFICATION_INTEGRATION_ID` | *(optional)* integration used to add the admin card |
   | `PAYMOB_ADMIN_CARD_VERIFY_AMOUNT` | *(optional, default `100` = 1 EGP)* used with the verification integration |
   | `PAYMOB_API_BASE` | *(optional, default `https://accept.paymob.com`)* |
   | `PAYMOB_CHECKOUT_BASE` | *(optional, default `https://eg.checkout.paymob.com/`)* |
   | `PAYMOB_REDIRECT_URL` | *(optional, default `com.myhato.app://payment-return`)* |
   | `ADMIN_DASHBOARD_URL` | *(optional)* where Paymob returns the admin after adding the admin card |

4. Admin dashboard → **إعدادات استقبال المدفوعات** → **التحقق من حساب Paymob**.
   - When the API key is valid and at least one integration ID is set, the account shows **متصل**.
   - Any missing secrets are listed by name.
5. Fill in IBAN, holder and bank name for reference. Choose whether refunds are allowed from the dashboard.
6. Press **تفعيل الدفع الإلكتروني**. Only then does "ادفع أونلاين" appear in the app's checkout. Until then the customer only sees cash on delivery and pay at branch.
7. Android: the manifest override in `app/tool/android_overrides/AndroidManifest.xml` already declares `com.myhato.app://payment-return`. No other native setup is needed, because there is no payment SDK in the app.

## Customer flow

1. Checkout → «ادفع أونلاين» (optionally tick «احفظ البطاقة») → the order is created with server-side prices and atomic stock.
2. `payments-create-intent` creates a Paymob **intention**:
   - The amount is read from the order row.
   - Saved card tokens are passed only for this customer.
   - An unexpired checkout for the same order is reused, so there is no double charge.
3. The app opens Paymob's checkout in an in-app browser tab and shows **حالة الدفع**. That screen listens to the server (realtime plus polling) and never trusts the redirect URL.
4. Paymob calls `payments-webhook`:
   - The HMAC is verified first.
   - Processing is **idempotent**: each transaction state is applied once.
   - Stale and out-of-order events are ignored.
   - An amount mismatch is flagged and the order is **not** marked paid.
   - If the customer opted in, a **TOKEN** callback stores the card token (Paymob reference, brand and last 4 only).
5. Statuses: **Pending, Succeeded, Failed, Cancelled, Refunded** (plus Partially refunded).
   - Customer and staff are notified.
   - A customer cannot cancel a paid order; staff refund it instead.

## Admin card (بطاقة المسؤول)

- Stored in its own single-row table, `admin_payment_method`. It is separate from the receiving bank account and from customer cards.
- **Never used to collect customer money.**
- Add or change: opens Paymob's page using the verification integration. The card becomes **مفعّلة** only after Paymob's signed callback.
- Remove: deletes our reference.

## Refunds

- Requires: Payments → «استرداد» button, permission `orders.manage`, and refunds enabled in settings.
- Partial or full, up to the remaining amount. A double-click lock stops the same refund being sent twice.
- The status changes only when Paymob's refund callback arrives.

## Sandbox tests (do these with TEST keys before going live)

| # | Test | Expected |
|---|---|---|
| 1 | Paymob test card, success | Order → مدفوع; payment ناجحة; email and notification sent |
| 2 | Test card declined | Payment فشلت; order stays unpaid; customer can retry |
| 3 | Close the checkout without paying | Status stays في الانتظار; retrying reuses the same checkout |
| 4 | Pay with «احفظ البطاقة» ticked | Card appears in «بطاقاتي» (brand •••• last4 only) |
| 5 | Pay without ticking | No card saved |
| 6 | Pay again with a saved card | Paymob shows the saved card; customer confirms |
| 7 | Remove a saved card | Disappears; never offered again |
| 8 | Mobile wallet test | Succeeds via callback |
| 9 | Admin refund (partial, then the rest) | مستردة جزئيًا → مستردة after the callback |
| 10 | Replay the same callback / change one field | Duplicate ignored / `401 invalid_hmac` |
| 11 | Admin card add → remove | مفعّلة after callback → تمت الإزالة |
| 12 | Disable online payments | Option disappears from checkout; create-intent returns `ONLINE_PAYMENTS_DISABLED` |

Automated tests:
- `supabase/tests/payments_test.sql` (P01–P08): idempotency, amount mismatch, stale events, refunds, token save rules, admin card, permissions.
- `supabase/functions/tests/paymob_hmac.test.ts`: HMAC (valid, tampered, wrong secret, TOKEN type).

> Some Paymob endpoint details differ between account generations (intention path, refund path, checkout host). They are configurable through the secrets above. Confirm them in the sandbox: one successful test payment, one refund and one replayed callback.

## Go-live checklist

1. KYC approved and the bank account registered with Paymob.
2. Switch all secrets to **live** keys and live integration IDs.
3. Set the callback URL on the **live** integrations.
4. Verify in the admin → **TEST** badge gone → enable online payments.
5. Make one real small payment, then refund it.

## Files

- **Database:**
  - `supabase/migrations/0010_payments_enums.sql`, `0011_payments.sql`, `0012_paymob.sql`
  - `supabase/manual/RUN_ONCE_IN_SQL_EDITOR.sql`
- **Edge Functions:**
  - `supabase/functions/_shared/paymob.ts`, `_shared/paymob_hmac.ts`
  - `payments-create-intent/`, `payments-webhook/`, `payments-methods/`, `payments-admin/`
- **Tests:** `supabase/tests/payments_test.sql`, `supabase/functions/tests/paymob_hmac.test.ts`
- **App:**
  - `lib/features/payments/*`: repository, Paymob checkout flow, status, saved cards, history, details
  - Checkout, order details, router `/payment-return`, Android manifest deep link
- **Admin:** `admin/app.js` pages for المدفوعات, إعدادات استقبال المدفوعات and بطاقة المسؤول
