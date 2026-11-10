#!/usr/bin/env bash
# CI entry point for the "MyHato Owner" Android app (.github/workflows/build-owner-apk.yml): the owner's AI chat, a separate app
# (package com.myhato.owner) that talks to the same Supabase database. Not the customer APK. Signed with the shop's permanent key.
set -uo pipefail
cd "$(dirname "$0")/.."
step() { echo; echo "=================== $* ==================="; }
step "flutter create (android)"
flutter create --platforms=android --org com.myhato --project-name myhato . || exit 1
rm -f test/widget_test.dart
cp tool/owner/AndroidManifest.xml android/app/src/main/AndroidManifest.xml
mkdir -p android/app/src/main/res/xml && cp tool/android_overrides/res/xml/update_file_paths.xml android/app/src/main/res/xml/
MA=$(find android/app/src/main -name MainActivity.kt | head -1)
[ -n "$MA" ] || { echo "FAILURE: MainActivity.kt not found"; exit 1; }
PKG=$(grep -m1 '^package ' "$MA" | awk '{print $2}')
sed "s/__PKG__/$PKG/" tool/android_overrides/MainActivity.kt.tpl > "$MA"   # fingerprint prompt + in-app update installer
for f in android/app/src/main/res/values/styles.xml android/app/src/main/res/values-night/styles.xml; do
  [ -f "$f" ] && sed -i -E 's#parent="@android:style/Theme\.(Light|Black)\.NoTitleBar"#parent="Theme.AppCompat.DayNight.NoActionBar"#g' "$f"
done
G=android/app/build.gradle; [ -f "$G.kts" ] && G="$G.kts"
sed -i -E 's/applicationId ?=? ?"[^"]+"/applicationId = "com.myhato.owner"/' "$G"
sed -i -E 's/minSdk ?=? ?flutter\.minSdkVersion/minSdk = 26/' "$G"

step "release signing"
KS="$PWD/android/app/myhato-release.jks"
if [ -n "${ANDROID_KEYSTORE_BASE64:-}" ]; then
  printf %s "$ANDROID_KEYSTORE_BASE64${ANDROID_KEYSTORE_BASE64_2:-}" | base64 -d > "$KS"
  ALIAS="${ANDROID_KEY_ALIAS:-myhato}"; SP="$ANDROID_KEYSTORE_PASSWORD"; KP="${ANDROID_KEY_PASSWORD:-$ANDROID_KEYSTORE_PASSWORD}"
elif [ -f tool/release.keystore.b64 ] && [ -f tool/release.key.env ]; then
  base64 -d tool/release.keystore.b64 > "$KS"
  # shellcheck disable=SC1091
  . tool/release.key.env
  SP="$PASS"; KP="$PASS"
else
  ALIAS=myhato; SP="$(head -c 24 /dev/urandom | base64 | tr -dc A-Za-z0-9)"; KP="$SP"
  keytool -genkeypair -keystore "$KS" -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 10000 -storepass "$SP" -keypass "$KP" -dname "CN=My Hato Owner, C=EG" >/dev/null 2>&1 || exit 1
fi
printf "storeFile=%s\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n" "$KS" "$SP" "$ALIAS" "$KP" > android/key.properties
python3 tool/patch_signing.py || exit 1
python3 tool/patch_desugar.py || exit 1
python3 tool/patch_compilesdk.py || exit 1
printf '\ndependencies {\n    implementation("androidx.core:core-ktx:1.13.1")\n}\n' >> "$G"

step "fonts"
mkdir -p assets/google_fonts
for w in Regular Medium Bold ExtraBold Black; do
  curl -sSfL "https://github.com/google/fonts/raw/main/ofl/tajawal/Tajawal-$w.ttf" -o "assets/google_fonts/Tajawal-$w.ttf" || echo "WARN: Tajawal-$w download failed"
done
step "pub get + icons"
flutter pub get || exit 1
dart run flutter_launcher_icons -f tool/owner/launcher_icons.yaml || echo "WARN: icons failed (non-fatal)"
step "flutter build apk --release (owner)"
flutter build apk --release --target-platform android-arm64 -t lib/owner_main.dart --build-number="${GITHUB_RUN_NUMBER:-1}" --obfuscate --split-debug-info=build/symbols \
  --dart-define=SUPABASE_URL=https://efdomvgypdkpqubkkjwm.supabase.co \
  --dart-define=BUILD_NUMBER="${GITHUB_RUN_NUMBER:-0}" \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVmZG9tdmd5cGRrcHF1YmtrandtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI2NjUzMjMsImV4cCI6MjEwODI0MTMyM30.EcvDTYBNfh2bka7UUA7gdcK12e8y4DnvOcIuGRmI4dg || exit 1
mkdir -p ../dist && cp build/app/outputs/flutter-apk/app-release.apk ../dist/MyHatoOwner.apk
if [ -n "${ANDROID_KEYSTORE_BASE64:-}" ] || [ -f tool/release.keystore.b64 ]; then echo ok > ../dist/stable-key.flag; fi
ls -la ../dist
step "BUILD OK"
