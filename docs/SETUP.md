# Backend & provider setup

Everything below is required before production. Nothing in the app pretends a provider works when it is not configured:
missing email/SMS/push providers leave records in `queued` / `failed` / `skipped_not_configured`, never "sent".

## 1. Database
```bash
supabase link --project-ref <ref>
supabase db push            # applies supabase/migrations/0001 … 0008
# demo data ONLY for staging:
psql "$STAGING_DB_URL" -f supabase/seed/dev_seed.sql
```
Production catalog, branches and delivery zones are created from the admin dashboard.

## 2. First owner account
1. Sign up once in the app or Supabase Auth with the owner's email.
2. In the SQL editor (runs as postgres, one time only):
   ```sql
   insert into public.user_roles(user_id, role)
   select id, 'owner' from auth.users where email = 'OWNER_EMAIL_HERE';
   ```
3. All other staff are invited from **Admin → Staff → Invite** (Edge Function `admin-invite-staff`). Public sign-up never grants staff roles.

## 3. Authentication (Supabase dashboard → Authentication)
| Setting | Value |
|---|---|
| **Phone provider** | Enable. Choose an SMS provider (Twilio / MessageBird / Vonage / Textlocal) and enter its credentials. |
| **SMS OTP Expiry** | **120 seconds** (the 2-minute rule is enforced by Supabase, not by the app timer). |
| SMS OTP Length | 6 |
| Rate limits → SMS sent | e.g. 30 / hour (project level) — Supabase also enforces a 60 s per-number resend cooldown, matching the app's resend button. |
| Bot protection (CAPTCHA) | Enable hCaptcha or Cloudflare Turnstile under *Attack Protection* for sign-up/sign-in/OTP. |
| Email | Enable "Confirm email". Set Site URL + Redirect URL `com.myhato.app://login-callback`. |
| **Google** | Create OAuth client (Web) in Google Cloud Console; authorised redirect `https://<ref>.supabase.co/auth/v1/callback`. Paste client ID/secret in Supabase. |
| **Facebook** | Create app at developers.facebook.com → Facebook Login; valid OAuth redirect `https://<ref>.supabase.co/auth/v1/callback`. Paste App ID/secret in Supabase. |
| Additional redirect URLs | `com.myhato.app://login-callback` |
| Manual linking | Leave **automatic linking by unverified email OFF**. Supabase links identities only for verified emails; phone is attached through the verified `phone_change` OTP flow in the app. |

Exact-lifetime note: Supabase validates OTP expiry server-side at the configured value. Delivery delays at the SMS
carrier reduce the usable window; the code can never be used after 120 s.

## 4. Edge Functions
```bash
supabase functions deploy process-email-outbox --no-verify-jwt     # protected by x-cron-secret
supabase functions deploy send-customer-notification --no-verify-jwt
supabase functions deploy secure-guest-repair-lookup --no-verify-jwt # public endpoint, rate-limited
supabase functions deploy admin-invite-staff                         # requires a signed-in owner JWT
```
Secrets (`supabase secrets set KEY=value`):

| Secret | Used by | Notes |
|---|---|---|
| `CRON_SECRET` | outbox & push workers | long random string |
| `RESEND_API_KEY` | process-email-outbox | Resend.com API key (or swap `sendViaResend` for your SMTP provider) |
| `EMAIL_FROM` | process-email-outbox | e.g. `My Hatō <noreply@your-domain.com>` — domain must be verified at the provider |
| `ADMIN_DASHBOARD_URL` | emails, invites | e.g. `https://admin.myhato.com` |
| `ADMIN_ALLOWED_ORIGINS` | CORS | comma-separated dashboard origins |
| `LOOKUP_CODE_PEPPER` | guest repair lookup | ≥ 16 random chars; codes are stored only as salted hashes |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM` | guest repair lookup SMS | without them the endpoint answers `SMS_NOT_CONFIGURED` |
| `TURNSTILE_SECRET_KEY` | guest repair lookup | optional CAPTCHA |
| `FCM_SERVICE_ACCOUNT_JSON` | push worker | Firebase service account JSON; without it push is logged as `skipped_not_configured` |

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected automatically by Supabase.

**Gmail recipients**: `myhatosales@gmail.com` and `myhatoservice@gmail.com` only *receive* mail; sending must go through a
transactional provider with a verified domain (Gmail SMTP from a server is unreliable and will be flagged as spam).

## 5. Schedules (pg_cron + pg_net)
Enable both extensions (Database → Extensions), then run the two `cron.schedule(...)` statements at the bottom of
`supabase/migrations/0007_delivery_workers.sql` with your project ref and `CRON_SECRET`. Emails then retry with exponential backoff
(1, 2, 4 … minutes, max 8 attempts). An email failure never touches the order or repair itself.

## 6. Realtime
Migration 0006 adds `notifications`, `order_status_history`, `repair_status_history`, `repair_quotes` to the
`supabase_realtime` publication. RLS applies to realtime events, so customers only receive their own rows.

## 7. Push notifications (optional)
Create a Firebase project, add the Android app `com.myhato.app`, download `google-services.json` into `app/android/app/`,
add `firebase_messaging` to the app and register the device token into `public.device_tokens` after sign-in.
The server side (`send-customer-notification`) is already implemented. Until then, in-app notifications (realtime) work.
