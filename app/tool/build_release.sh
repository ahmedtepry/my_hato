#!/usr/bin/env bash
# Builds the release APK + AAB against the live My Hatō Supabase project.
set -euo pipefail
cd "$(dirname "$0")/.."
DEFINES=(
  --dart-define=SUPABASE_URL=https://ytncfollpvkvlmtpxmzg.supabase.co
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl0bmNmb2xscHZrdmxtdHB4bXpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ5OTQ2OTMsImV4cCI6MjExMDU3MDY5M30.FzKq68QcVzFRO503KlXaH_lBJ59Nto_-Hn4anNPxWhg
  --dart-define=SUPPORT_PHONE=${SUPPORT_PHONE:-}
  --dart-define=SUPPORT_WHATSAPP=${SUPPORT_WHATSAPP:-}
)
flutter pub get
flutter test
flutter build apk --release --obfuscate --split-debug-info=build/symbols "${DEFINES[@]}"
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols "${DEFINES[@]}"
echo "APK: build/app/outputs/flutter-apk/app-release.apk"
echo "AAB: build/app/outputs/bundle/release/app-release.aab"
