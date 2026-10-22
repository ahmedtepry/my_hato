#!/usr/bin/env bash
# Builds the release APK + AAB against the live My Hatō Supabase project.
set -euo pipefail
cd "$(dirname "$0")/.."
DEFINES=(
  --dart-define=SUPABASE_URL=https://efdomvgypdkpqubkkjwm.supabase.co
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVmZG9tdmd5cGRrcHF1YmtrandtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI2NjUzMjMsImV4cCI6MjEwODI0MTMyM30.EcvDTYBNfh2bka7UUA7gdcK12e8y4DnvOcIuGRmI4dg
  --dart-define=SUPPORT_PHONE=${SUPPORT_PHONE:-}
  --dart-define=SUPPORT_WHATSAPP=${SUPPORT_WHATSAPP:-}
)
flutter pub get
flutter test
flutter build apk --release --obfuscate --split-debug-info=build/symbols "${DEFINES[@]}"
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols "${DEFINES[@]}"
echo "APK: build/app/outputs/flutter-apk/app-release.apk"
echo "AAB: build/app/outputs/bundle/release/app-release.aab"
