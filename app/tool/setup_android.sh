#!/usr/bin/env bash
# Generates the android/ platform folder (not committed) and applies My Hatō settings.
# Run from app/:  ./tool/setup_android.sh
set -euo pipefail
cd "$(dirname "$0")/.."
flutter create --platforms=android --org com.myhato --project-name myhato . >/dev/null
cp tool/android_overrides/AndroidManifest.xml android/app/src/main/AndroidManifest.xml
G=android/app/build.gradle; [ -f "$G.kts" ] && G="$G.kts"
# applicationId + minSdk 23 (required by supabase/app_links)
sed -i -E 's/applicationId ?=? ?"[^"]+"/applicationId = "com.myhato.app"/' "$G"
sed -i -E 's/minSdk ?=? ?flutter\.minSdkVersion/minSdk = 23/' "$G"
flutter pub get
dart run flutter_launcher_icons
dart run flutter_native_splash:create
echo "Android project ready. Next: configure release signing (docs/ANDROID_RELEASE.md)."
