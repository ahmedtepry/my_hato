#!/usr/bin/env bash
# CI entry point (.github/workflows/build-apk.yml). Builds a RELEASE APK signed with the release key.
# Signing: if ANDROID_KEYSTORE_BASE64 (+ ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD) are set as
# GitHub secrets, that key is used (same key for every build -> app updates install over each other).
# Otherwise a temporary key is generated for this build only (fine for review installs; uninstall before the next one).
set -uo pipefail
cd "$(dirname "$0")/.."
step() { echo; echo "=================== $* ==================="; }
step "flutter --version"; flutter --version
step "flutter create (android)"
flutter create --platforms=android --org com.myhato --project-name myhato . || exit 1
rm -f test/widget_test.dart   # template test from flutter create (we ship our own tests)
cp tool/android_overrides/AndroidManifest.xml android/app/src/main/AndroidManifest.xml
G=android/app/build.gradle; [ -f "$G.kts" ] && G="$G.kts"
sed -i -E 's/applicationId ?=? ?"[^"]+"/applicationId = "com.myhato.app"/' "$G"
sed -i -E 's/minSdk ?=? ?flutter\.minSdkVersion/minSdk = 23/' "$G"

step "release signing"
KS="$PWD/android/app/myhato-release.jks"
if [ -n "${ANDROID_KEYSTORE_BASE64:-}" ]; then
  echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > "$KS"
  ALIAS="${ANDROID_KEY_ALIAS:-myhato}"; SP="$ANDROID_KEYSTORE_PASSWORD"; KP="${ANDROID_KEY_PASSWORD:-$ANDROID_KEYSTORE_PASSWORD}"
  echo "using release key from GitHub secrets"
else
  ALIAS=myhato; SP="$(head -c 24 /dev/urandom | base64 | tr -dc A-Za-z0-9)"; KP="$SP"
  keytool -genkeypair -v -keystore "$KS" -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$SP" -keypass "$KP" -dname "CN=My Hato, O=My Hato, C=EG" >/dev/null 2>&1 || exit 1
  echo "WARNING: no ANDROID_KEYSTORE_BASE64 secret — signed with a temporary key generated for this build"
fi
printf "storeFile=%s\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n" "$KS" "$SP" "$ALIAS" "$KP" > android/key.properties
python3 tool/patch_signing.py || exit 1
python3 tool/patch_desugar.py || exit 1
python3 tool/patch_compilesdk.py || exit 1
grep -nE "applicationId|minSdk|signingConfig" "$G"

step "bundle fonts"
mkdir -p assets/google_fonts
for w in Regular Medium Bold ExtraBold Black; do
  curl -sSfL "https://github.com/google/fonts/raw/main/ofl/tajawal/Tajawal-$w.ttf" -o "assets/google_fonts/Tajawal-$w.ttf" || echo "WARN: Tajawal-$w download failed"
done
for w in Regular Medium SemiBold Bold ExtraBold Black; do
  curl -sSfL "https://github.com/google/fonts/raw/main/ofl/poppins/Poppins-$w.ttf" -o "assets/google_fonts/Poppins-$w.ttf" || echo "WARN: Poppins-$w download failed"
done
ls -la assets/google_fonts
step "flutter pub get"; flutter pub get || exit 1
step "launcher icons"; dart run flutter_launcher_icons || echo "WARN: icons step failed (non-fatal)"
step "splash"; dart run flutter_native_splash:create || echo "WARN: splash step failed (non-fatal)"
step "flutter analyze"; flutter analyze --no-fatal-infos --no-fatal-warnings; echo "analyze exit=$?"
step "avatar preview"; flutter test --update-goldens test/avatars_golden_test.dart test/product_grid_golden_test.dart; echo "golden exit=$?"
step "flutter test"; flutter test; echo "test exit=$?"
step "release guards"; flutter test test/no_hero_test.dart || { echo "FAILURE: release guard (Hero widgets) failed"; exit 1; }
step "flutter build apk --release"
build_apk() {
  flutter build apk --release --obfuscate --split-debug-info=build/symbols \
    --dart-define=SUPABASE_URL=https://efdomvgypdkpqubkkjwm.supabase.co \
    --dart-define=APP_VERSION="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')" \
    --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVmZG9tdmd5cGRrcHF1YmtrandtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI2NjUzMjMsImV4cCI6MjEwODI0MTMyM30.EcvDTYBNfh2bka7UUA7gdcK12e8y4DnvOcIuGRmI4dg
}
if ! build_apk; then
  # transient SDK/NDK download failures ("Error on ZipFile unknown archive") leave a half-installed
  # package behind: remove partial downloads and try once more
  echo "WARN: build failed — cleaning partial Android SDK downloads and retrying once"
  SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/usr/local/lib/android/sdk}}"
  rm -rf "$SDK"/ndk/*.temp "$SDK"/.temp "$SDK"/temp 2>/dev/null || true
  for d in "$SDK"/ndk/*/; do [ -f "$d/source.properties" ] || rm -rf "$d"; done
  sleep 20
  build_apk || exit 1
fi
mkdir -p ../dist && cp build/app/outputs/flutter-apk/app-release.apk ../dist/myhato-release.apk
keytool -printcert -jarfile ../dist/myhato-release.apk 2>/dev/null | head -8 || true
ls -la ../dist
step "BUILD OK"
