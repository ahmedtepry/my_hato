# My Hatō — YOUR PHONE. OUR PRIORITY.

منصة بيع موبايلات وإكسسوارات + خدمة صيانة:

| الجزء | المسار | التقنية |
|---|---|---|
| تطبيق العميل (أندرويد) | `app/` | Flutter · Riverpod · GoRouter · عربي (RTL) + English (LTR) |
| لوحة تحكم الأدمن | `admin/` | صفحة ويب بدون build (HTML/JS) · عربي + English |
| قاعدة البيانات والصلاحيات | `supabase/migrations/` | PostgreSQL + RLS + دوال PL/pgSQL ذرّية |
| منطق السيرفر | `supabase/functions/` | Supabase Edge Functions (Deno) |
| الاختبارات | `supabase/tests/`, `supabase/functions/tests/`, `app/test/` | |

## Email routing
* **New orders** → `myhatosales@gmail.com`
* **Repair requests & customer quote replies** → `myhatoservice@gmail.com`

Both addresses live in `application_settings` and can be changed from **Admin → Settings** without redeploying.

## "مستعمل / Used" section
Shown in the top section bar next to **هواتف · إكسسوارات · صيانة**. While `used_devices_enabled = false`
(default) it opens a **"قريبًا / Coming soon"** page. To launch it later: add products under a category of
kind **used** (Admin → Categories) and switch on **Admin → Settings → Enable the Used section**. No app update needed.

## Quick start
1. Create a Supabase project. Apply migrations in order (`supabase/migrations/0001…0008`) with the Supabase CLI
   (`supabase db push`) or the SQL editor. Optionally load `supabase/seed/dev_seed.sql` (demo data only).
2. Follow **[docs/SETUP.md](docs/SETUP.md)** — Auth providers (Phone OTP 120 s, Google, Facebook), Edge Function secrets, email provider, cron jobs, first owner account.
3. Admin dashboard: copy `admin/config.example.js` → `admin/config.js`, deploy the folder (see [docs/DEPLOY_ADMIN.md](docs/DEPLOY_ADMIN.md)).
4. Android app: see **[docs/ANDROID_RELEASE.md](docs/ANDROID_RELEASE.md)**.

## Docs
* [docs/SETUP.md](docs/SETUP.md) — backend & third-party configuration
* [docs/SCHEMA.md](docs/SCHEMA.md) — tables, relationships, functions, policies, buckets
* [docs/SECURITY.md](docs/SECURITY.md) — security model & checklist, remaining risks
* [docs/ANDROID_RELEASE.md](docs/ANDROID_RELEASE.md) — APK/AAB build, signing, Play Store checklist
* [docs/DEPLOY_ADMIN.md](docs/DEPLOY_ADMIN.md) — dashboard hosting & headers
* [docs/BACKUP.md](docs/BACKUP.md) — backup & recovery
* [docs/PAYMENTS.md](docs/PAYMENTS.md) — online payments (Stripe), go-live steps and tests
* [docs/LIVE_PROJECT.md](docs/LIVE_PROJECT.md) — the deployed Supabase project
* [docs/STATUS.md](docs/STATUS.md) — **what is done, what was tested, what still needs credentials**

## Running the tests
```bash
# Backend (needs a local PostgreSQL 16; uses a stub of Supabase's auth/storage schemas)
PGHOST=... PGUSER=postgres ./supabase/tests/run.sh
PGHOST=... PGUSER=postgres ./supabase/tests/concurrency_test.sh
# Edge Function templates/helpers
node --experimental-strip-types --test supabase/functions/tests/templates.test.ts
# Flutter
cd app && flutter test
```
