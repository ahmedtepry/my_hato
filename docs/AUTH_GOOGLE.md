# Sign in with Google

The app signs in with Google through Supabase Auth in the browser (Custom Tab) and returns to the
app via `com.myhato.app://login-callback`. This flow does not depend on the APK signing key.
The Google button appears automatically once the provider is enabled (the app reads
`/auth/v1/settings`); until then it is hidden.

## 1. Google Cloud (console.cloud.google.com)
1. Create a project, e.g. **My Hato**.
2. **APIs & Services → OAuth consent screen** (Google Auth Platform → Branding / Audience):
   - User type **External**, app name **My Hatō**, support email, logo (optional).
   - Authorized domain: `supabase.co`
   - Scopes: `openid`, `email`, `profile` (no verification needed for these).
   - **Audience → Publish app** (move from *Testing* to *In production*) so every Google user can sign in.
     While in *Testing*, only the test users you list can sign in.
3. **Credentials → Create credentials → OAuth client ID → Web application**
   - Name: `Supabase`
   - Authorized redirect URI: `https://efdomvgypdkpqubkkjwm.supabase.co/auth/v1/callback`
   - Copy the **Client ID** and **Client secret**.

## 2. Supabase (project myhato-store)
1. **Authentication → Sign In / Providers → Google** → enable, paste Client ID and Client secret → Save.
2. **Authentication → URL Configuration → Redirect URLs**: make sure `com.myhato.app://login-callback` is listed.

## 3. Test
Open the app → تسجيل الدخول → «المتابعة بـ Google» → choose an account → you return to the app signed in.
Google accounts arrive with a confirmed email, so the account is verified automatically.

Facebook works the same way (Supabase → Providers → Facebook, with an app from developers.facebook.com and
redirect URI `https://efdomvgypdkpqubkkjwm.supabase.co/auth/v1/callback`).
