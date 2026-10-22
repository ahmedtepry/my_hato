# Security model & checklist

## Principles
* **The database is the security boundary.** Every table has RLS; privileged writes happen only inside permission-checked
  `SECURITY DEFINER` functions with a pinned `search_path`. Hidden buttons in the app/dashboard are UX only.
* **Clients never send prices, totals, stock or statuses as facts.** `place_order` re-reads and locks products, computes prices,
  discount and delivery fee, and decrements stock in one transaction (`CHECK stock_quantity >= 0` as last defence).
* **No secrets in the APK or dashboard.** Only the publishable anon key. Service role, SMTP/Resend, Twilio, FCM, pepper → Edge Function secrets.
* **OTP**: generated, delivered and verified by Supabase Auth; lifetime set to 120 s server-side; codes never stored by us.
  Guest repair-lookup codes are stored only as peppered SHA-256 hashes, expire in 120 s, max 5 attempts, single use.

## Verified by automated tests (supabase/tests — executed, passing)
| # | Check |
|---|---|
| T02 | customer cannot set `phone_verified` or grant themselves a role |
| T03 | anonymous users see only published products |
| T05 | anonymous users cannot place orders |
| T06 | customers cannot write cart rows directly |
| T07 | unverified phone cannot order |
| T08 | idempotent order creation, server totals, sales email queued once |
| T09 + concurrency test | oversell impossible, even with two simultaneous buyers of the last unit |
| T11 | customer A cannot read B's orders, items, addresses, profile, or cancel B's order |
| T12 | invalid order transitions rejected; technician cannot manage orders |
| T15 | customers cannot read `internal_notes` or call staff functions; B cannot see A's repair |
| T16 | unassigned technician cannot update a repair *(this test found and fixed a NULL-logic bypass during development)* |
| T17 | chargeable repair cannot start before approval |
| T18 | B cannot approve A's quote; technician cannot record approvals |
| T20 | guest lookup payload has no IMEI/address/phone/internal notes; not callable by API roles |
| T21 | audit log append-only and hidden from customers |
| T22 | private repair photos unreadable by other customers; cannot upload into another customer's folder |
| T23 | sales cannot escalate to owner |
| W03 | worker functions not callable by customers |
| P01–P08 | online payments off until provider verified; merchant settings hidden from non-owners; `is_configured` not client-writable; server-side amount; no double charge; amount-mismatch rejected; webhook events idempotent and stale events ignored; customers can't write payments/cards; refunds permission-checked and capped; admin card isolated |
| HMAC tests | Paymob callback HMAC-SHA512 verified (TRANSACTION + TOKEN); tampered fields or wrong secret rejected |

## Production checklist
- [ ] Phone OTP expiry = 120 s, CAPTCHA enabled, SMS rate limits set
- [ ] Google + Facebook OAuth redirect URLs restricted to Supabase callback + `com.myhato.app://login-callback`
- [ ] Email confirmation ON; automatic linking by unverified email OFF
- [ ] All Edge Function secrets set; `CRON_SECRET` and `LOOKUP_CODE_PEPPER` random ≥ 32 chars
- [ ] `ADMIN_ALLOWED_ORIGINS` = exact dashboard origin(s)
- [ ] Dashboard served over HTTPS with headers from DEPLOY_ADMIN.md (CSP, frame-ancestors, HSTS)
- [ ] Run Supabase **Security Advisor** and fix any findings
- [ ] Enable Point-in-Time Recovery (Pro plan) or daily backups (BACKUP.md)
- [ ] Owner account uses a strong password + MFA (Auth → MFA)
- [ ] Release APK built with `--obfuscate --split-debug-info`; keystore stored outside the repo
- [ ] Review privacy policy text with a lawyer (Egyptian Personal Data Protection Law No. 151/2020)

## Remaining risks (honest list)
* SMS delivery and OTP abuse costs depend on the SMS provider's own fraud controls — set spending caps.
* The guest lookup endpoint is protected by rate limits; enable Turnstile for stronger bot protection.
* Staff accounts are high-value targets: enforce MFA; review `audit_logs` regularly.
* Supabase realtime delivers only rows passing RLS, but clients still re-fetch from the DB as source of truth.
* No system is immune to attack; keep dependencies updated (`flutter pub outdated`, Supabase CLI updates).

## Supabase Security Advisor (live project, after deployment)
* No errors. Remaining notices are intentional:
  * "RLS enabled, no policy" on `payment_customers`, `rate_limits`, `repair_lookup_challenges` — service-role-only tables (deny-all to clients).
  * "SECURITY DEFINER callable by signed-in users" — these are the app's RPC API (`place_order`, `staff_*`, …); each one checks
    `auth.uid()` / role permissions inside before doing anything (verified by tests T05–T23, P01–P08).
  * `has_permission`, `is_staff`, `product_is_public` callable by anon — used by public catalog RLS policies; they only answer questions about the caller.
