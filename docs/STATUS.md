# Project status (honest)

## Done & executed in this environment
| Area | Evidence |
|---|---|
| 8 SQL migrations (schema, constraints, RLS, storage, realtime, business functions) | applied cleanly to PostgreSQL 16 |
| Backend integration & authorization tests T01–T24 + worker tests W01–W03 | **all passing** (`supabase/tests/run.sh`) |
| Concurrency test (2 buyers, last unit) | **passing** — exactly one order, stock ends at 0 |
| Edge Function email templates & crypto helpers | 6/6 Node tests passing |
| Admin dashboard | every page rendered in headless Chromium in Arabic, English and at 390 px phone width with no JS errors (mock backend) |
| Email routing | orders → myhatosales@gmail.com (T08), repairs + quote replies → myhatoservice@gmail.com (T14, T19) |
| "مستعمل" section | Coming-soon page in app (AR/EN) + backend flag `used_devices_enabled` + admin toggle (T24) |
| Live chat backend (migration 0010) | applied to the live project and exercised with 2 customers + a support agent + a technician: tenant isolation, direct-write blocked, closed-chat blocked, fake/bad attachments blocked, double rating blocked, retry de-duplication, notification + queued push created; test data rolled back |

## Written but NOT compiled/executed here
* **Flutter app** (`app/`) and its tests: this workspace has no Flutter/Dart SDK and cannot download it (network policy),
  so the code has not been compiled. Run `flutter pub get && flutter analyze && flutter test` on a machine with Flutter 3.24 and fix any analyzer findings before release.
* **Live chat UI** (`app/lib/features/support_chat/` and the dashboard page `#/support`): written against the tested backend, but not run on a device/browser here. Check on a phone: send/receive, image + PDF, typing, read ticks, close → rating.
* **Edge Functions** (Deno): not executed against a live Supabase project (no Deno/Supabase CLI here).
* **APK/AAB**: not built — no Android SDK/Flutter available. Exact commands are in ANDROID_RELEASE.md.

## Needs your credentials / accounts
| Item | Where |
|---|---|
| Supabase project (URL + anon key) | SETUP §1, build `--dart-define`s, `admin/config.js` |
| SMS provider for Phone OTP (Twilio etc.) + OTP expiry 120 s | Supabase Auth |
| Google OAuth client, Facebook app | Supabase Auth |
| Transactional email provider (Resend or SMTP) with a verified sending domain | Edge secrets `RESEND_API_KEY`, `EMAIL_FROM` |
| Firebase (push) — optional | `FCM_SERVICE_ACCOUNT_JSON` + `firebase_messaging` in app |
| Android release keystore | ANDROID_RELEASE §2 |
| Real branches, delivery fees, products, banners | Admin dashboard |
| Final logo vector | replace `app/assets/brand/*` and `BrandMark` painter |

## Design decisions to confirm
* Brand colours follow the **attached brand board** (Navy #0B2D5B, Electric #00A3FF, Off-white #F8F9FA) rather than the
  hex values in the written spec (#0B1630 / #246BFD). They are defined once in `app/lib/core/theme.dart` and `admin/styles.css`.
* Online payments (Paymob Egypt: Visa/Mastercard/Meeza, Apple Pay, mobile wallets, Google Pay if Paymob enables it, saved cards) are implemented but **off until you connect your Paymob account** — see PAYMENTS.md.
* Guest repair lookup requires SMS; until an SMS provider is set, guests are told to sign in.
