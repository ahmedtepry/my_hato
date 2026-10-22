# Android release (APK / AAB)

Tested toolchain target: **Flutter 3.24.x stable** (Dart 3.5), Android SDK 34, JDK 17.

## 1. Generate the platform folder & icons
```bash
cd app
./tool/setup_android.sh        # flutter create (android only), manifest, applicationId com.myhato.app, minSdk 23, icons, splash
```
The launcher icon and splash use `assets/brand/` (cropped from the brand board — replace with the original vector export for best quality).

## 2. Release signing (never commit these files)
```bash
keytool -genkey -v -keystore ~/myhato-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias myhato
```
`app/android/key.properties`:
```
storePassword=***
keyPassword=***
keyAlias=myhato
storeFile=/absolute/path/myhato-release.jks
```
In `android/app/build.gradle(.kts)` load `key.properties` and set `signingConfigs.release`, then `buildTypes.release.signingConfig = signingConfigs.release`
(standard Flutter docs: https://docs.flutter.dev/deployment/android#sign-the-app). `key.properties` and `*.jks` are in `.gitignore`.

## 3. Build
```bash
DEFINES="--dart-define=SUPABASE_URL=https://<ref>.supabase.co --dart-define=SUPABASE_ANON_KEY=<publishable key> --dart-define=SUPPORT_PHONE=+20... --dart-define=SUPPORT_WHATSAPP=20..."
flutter test
flutter build apk --release --obfuscate --split-debug-info=build/symbols $DEFINES     # build/app/outputs/flutter-apk/app-release.apk
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols $DEFINES # build/app/outputs/bundle/release/app-release.aab
```
Version: bump `version: 1.0.0+1` in `pubspec.yaml` (name+build number) for every upload.

## 4. Smoke test on a device
```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```
1. Switch language AR ↔ EN (layout flips RTL/LTR) · 2. Sign in by phone OTP (wait > 2 min once: code must be rejected) ·
3. Google + Facebook sign-in return to the app · 4. Browse, filter, sort by lowest price · 5. Add to cart, checkout pickup & delivery ·
6. Confirmation animation + message · 7. Admin changes order status → app updates live · 8. Repair request with photos → service email arrives ·
9. Admin sets 200 EGP quote → approve in app · 10. "مستعمل" shows "قريبًا".

## 5. Crash reporting
Recommended: Firebase Crashlytics or Sentry (`sentry_flutter`) — upload `build/symbols` for de-obfuscated stack traces. Never log personal data.

## 6. Play Store checklist
- [ ] App name "My Hatō", short/long description AR + EN, screenshots (phone), feature graphic 1024×500, 512×512 icon
- [ ] Privacy policy URL (host the text from the Legal screen)
- [ ] Data safety form: name, phone, email, address, photos (repair), purchase history; encrypted in transit; deletion request supported
- [ ] Account deletion URL / in-app path (Account → Request account deletion)
- [ ] Content rating questionnaire, target audience 18+ (commerce)
- [ ] Release on internal testing track first
- [ ] Add the Play App Signing SHA-1/SHA-256 to Google OAuth and Firebase if used
