# Live Supabase project

| | |
|---|---|
| Project | **myhato-store** (`efdomvgypdkpqubkkjwm`), region eu-central-1 (Frankfurt) |
| API URL | https://efdomvgypdkpqubkkjwm.supabase.co |
| Dashboard | https://supabase.com/dashboard/project/efdomvgypdkpqubkkjwm |

## Already done
* All migrations 0001–0009 applied (42 tables, RLS on every table, 61 functions, 5 storage buckets, realtime).
* Default categories (incl. **مستعمل / used**, disabled = "قريبًا") and brands inserted. No demo products/branches.
* Edge Functions deployed: `process-email-outbox`, `secure-guest-repair-lookup`, `send-customer-notification`, `admin-invite-staff`.
* End-to-end test on the live database (rolled back): order → `myhatosales@gmail.com`, repair + quote approval →
  `myhatoservice@gmail.com`, 200 EGP quote message, stock decrement — all correct.
* `admin/config.js` and `app/tool/build_release.sh` point at this project.

* Payments: migrations 0010–0012 (Paymob) + Edge Functions `payments-create-intent`, `payments-webhook`, `payments-methods`, `payments-admin` deployed (online payments OFF until your Paymob account is connected).

## Still to do (needs your accounts — Supabase dashboard)
0. Paste `supabase/manual/RUN_ONCE_IN_SQL_EDITOR.sql` into the SQL editor once (saved-card removal; the deploy tool refused it).
0. Payments: follow **docs/PAYMENTS.md** (Paymob merchant account, callback URL, secrets, verify + enable from admin).
1. **Owner account**: sign up once (admin page or app), then in SQL editor:
   `insert into public.user_roles(user_id, role) select id, 'owner' from auth.users where email = 'YOUR_EMAIL';`
2. **Auth → Providers**: Phone (SMS provider + OTP expiry 120 s), Google, Facebook; redirect URL `com.myhato.app://login-callback`.
3. **Edge Function secrets** (Settings → Edge Functions): `CRON_SECRET`, `RESEND_API_KEY`, `EMAIL_FROM`, `LOOKUP_CODE_PEPPER`,
   `ADMIN_DASHBOARD_URL`, `ADMIN_ALLOWED_ORIGINS` (+ Twilio / FCM optional). Until then emails stay queued — orders are never lost.
4. **Cron**: enable `pg_cron` + `pg_net`, run the two `cron.schedule` statements in migration 0007 with your `CRON_SECRET`.
5. Add branches, delivery fees and products from the admin dashboard.
