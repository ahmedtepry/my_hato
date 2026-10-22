# Account verification by email code (OTP)

The app verifies every email/password account with a **6-digit code** sent by **Supabase Auth**.
Supabase generates, sends, expires and checks the codes. The app only shows the screen where the
code is typed, and the database marks the account as verified when Supabase confirms the email
(`profiles.email_verified`, migration `0013_account_verification.sql`). Placing an order requires a
verified account (email **or** phone) and a reachable mobile number.

| Flow | Where in the app | Supabase call | Email template |
|---|---|---|---|
| Create account → verify | إنشاء حساب → شاشة الكود | `signUp` → `verifyOTP(type: signup)` | **Confirm sign up** |
| Sign in without password | تسجيل الدخول → «الدخول بكود على الإيميل» | `signInWithOtp(shouldCreateUser: false)` → `verifyOTP(type: email)` | **Magic link** |
| Forgot password | «نسيت كلمة المرور؟» → كود → كلمة مرور جديدة | `resetPasswordForEmail` → `verifyOTP(type: recovery)` → `updateUser(password)` | **Reset password** |
| Old unverified account signs in | تسجيل الدخول | sign-in returns `email_not_confirmed` → `resend(type: signup)` | **Confirm sign up** |

Google and Facebook accounts arrive with a confirmed email, so they are verified automatically.

## One-time setup in the Supabase dashboard (project `myhato-store`)

1. **Authentication → Sign In / Providers → Email**
   - *Enable Email provider*: on
   - *Confirm email*: **on**
   - *Email OTP Expiration*: **600** seconds (the app shows a 10-minute countdown)
   - *Email OTP Length*: **6**
   - *Secure email change*: on
2. **Authentication → Emails → Templates**: paste each file from `supabase/templates/` into its template and set the subject.

   | Template | File | Subject |
   |---|---|---|
   | Confirm sign up | `confirm_signup.html` | `{{ .Token }} كود توثيق حسابك في My Hatō` |
   | Magic link | `magic_link.html` | `{{ .Token }} كود الدخول إلى My Hatō` |
   | Reset password | `reset_password.html` | `{{ .Token }} كود استعادة كلمة المرور — My Hatō` |
   | Change email address | `change_email.html` | `تأكيد الإيميل الجديد — My Hatō` |

   The templates show the code (`{{ .Token }}`) instead of a link. If a template still contains only
   `{{ .ConfirmationURL }}`, customers receive a link and no code.
3. **Authentication → URL Configuration → Redirect URLs**: keep `com.myhato.app://login-callback`.
4. **Authentication → Emails → SMTP Settings** (required before real customers): see below.

## Email delivery (required for production)

Without custom SMTP, Supabase's built-in sender **only delivers to members of your Supabase team**
(so it works for `ahmedtepry@gmail.com` while testing) and is limited to a few emails per hour.
Real customers will not receive codes until custom SMTP is set.

Recommended: **Resend** (also used for the order and repair emails).
1. Create an account at resend.com and add your domain (e.g. `myhato.com`), then add the DNS records it shows (SPF, DKIM).
2. Create an API key.
3. Supabase → Authentication → Emails → **SMTP Settings** → *Enable custom SMTP*:
   - Host `smtp.resend.com`, Port `465`, Username `resend`, Password = the API key
   - Sender email `noreply@<your-domain>`, Sender name `My Hatō`
4. Authentication → **Rate Limits**: raise *emails per hour* to fit your traffic (e.g. 100).
5. Put the same key in Edge Function secrets as `RESEND_API_KEY` (order/repair emails).

## Security notes
- Codes are single-use, expire after 10 minutes, and each resend invalidates the previous code (Supabase Auth).
- Resend is limited to once every 60 seconds per email (Supabase default; the app shows the countdown).
- "Sign in with a code" never creates an account (`shouldCreateUser: false`).
- Messages never reveal whether an email is registered (password reset always shows the same text).
- `email_verified` / `phone_verified` are written only by database triggers from `auth.users`; customers cannot change them (test T07b).

## Test checklist
1. Create an account with your team email → the email shows a 6-digit code → enter it → «تم توثيق حسابك بنجاح» and you are signed in.
2. Enter a wrong code → «الكود غلط أو انتهت صلاحيته»; resend → old code rejected, new code works.
3. Wait 10 minutes → code rejected.
4. Sign out → «الدخول بكود على الإيميل» → code → signed in.
5. «نسيت كلمة المرور؟» → code → new password → sign in with it.
6. Profile shows «حساب موثّق»; checkout asks for a mobile number if none is saved (pickup orders).
