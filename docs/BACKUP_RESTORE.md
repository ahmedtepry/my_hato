# MyHato — نسخة احتياطية واسترجاع

## النسخة الاحتياطية (أوتوماتيك كل ليلة)

- الـ workflow اسمه `db-backup` على فرع `main`، وبيشتغل كل يوم الساعة ٢:٤٠ بتوقيت القاهرة.
- بياخد نسخة من:
  - جداول `public` وبياناتها كلها.
  - حسابات الدخول (`auth.users` و `auth.identities`).
  - الـ buckets.
  - المهام المجدولة، والـ triggers على الحسابات، وسياسات التخزين.
- الملف بيتشفّر بـ AES-256، وكلمة السر موجودة **بس** في الـ secret اللي اسمه `BACKUP_PASSPHRASE`.
- النسخة بتتحفظ في صفحة الـ workflow تحت **Artifacts**: نسخة كل ليلة بتفضل ٣٠ يوم، ونسخة يوم الحد بتفضل ٩٠ يوم.
- لو النسخة فشلت، GitHub بيبعت إيميل لصاحب المستودع.

### الإعداد (مرة واحدة)

من المستودع على GitHub، ادخل على Settings، وبعدين Secrets and variables، وبعدين Actions، وبعدين New repository secret:

| الاسم | القيمة |
|---|---|
| `BACKUP_DB_URL` | `postgresql://backup_reader.<project-ref>:<password>@aws-1-eu-central-1.pooler.supabase.com:5432/postgres` |
| `BACKUP_PASSPHRASE` | كلمة سر طويلة إنت تختارها (١٦ حرف على الأقل). **احفظها في مكان آمن، من غيرها مفيش نسخة تتفتح.** |

`backup_reader` حساب قراءة بس (`pg_read_all_data`)، يعني مش بيقدر يغيّر أي حاجة.

## الاسترجاع على مشروع Supabase جديد

1. نزّل الملف `myhato-db-YYYY-MM-DD.sql.gz.enc` من صفحة الـ workflow.
2. فك التشفير:
   ```
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 300000 -in myhato-db-2026-11-18.sql.gz.enc -out backup.sql.gz
   gunzip backup.sql.gz
   ```
3. في المشروع الجديد: فعّل الإضافات `pg_trgm`, `vector`, `uuid-ossp`, `pgcrypto` (في schema `extensions`)، و `pg_cron` و `pg_net`.
4. حمّل الأجزاء بالترتيب بـ `psql` كمستخدم `postgres` بتاع المشروع الجديد. الملف مقسوم بعناوين:
   1. الجزء ١ (الجداول والبيانات).
   2. الجزء ٢ بعد `SET session_replication_role = replica;`.
   3. الجزء ٣ (المهام والـ triggers والسياسات).
   - قبل التحميل، امسح سطور `ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin` لو موجودة.
5. انزّل الـ Edge Functions من `supabase/functions` على المشروع الجديد. وحط الـ secrets بتاعة الخدمات الخارجية: Gemini والدفع والإشعارات.
6. غيّر عنوان المشروع والمفتاح العام في:
   - `app/tool/ci_build.sh`
   - `app/tool/ci_build_owner.sh`
   - `.github/workflows/build-*.yml`
   - `site/`
   
   وبعدين ابني التلات تطبيقات.

لنقل مباشر من مشروع لمشروع، فيه كمان الـ workflow اللي اسمه `db-migrate`، واستخدمناه في نقل ١٨ نوفمبر ٢٠٢٦.
