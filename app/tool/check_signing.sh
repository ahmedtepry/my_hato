#!/usr/bin/env bash
# Prints PASS/FAIL per signing secret (never the values) + the certificate fingerprint of the key.
set -u
K=$(mktemp -d)/k.jks
[ -n "${ANDROID_KEYSTORE_BASE64:-}" ] || { echo "FAIL ANDROID_KEYSTORE_BASE64 is empty/missing"; exit 1; }
printf %s "$ANDROID_KEYSTORE_BASE64${ANDROID_KEYSTORE_BASE64_2:-}" | base64 -d > "$K" 2>/dev/null || echo "FAIL ANDROID_KEYSTORE_BASE64 is not valid base64"
echo "keystore file bytes: $(wc -c < "$K")"
SP="${ANDROID_KEYSTORE_PASSWORD:-}"; AL="${ANDROID_KEY_ALIAS:-}"; KP="${ANDROID_KEY_PASSWORD:-}"
for n in ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD UPDATE_PUSH_SECRET; do [ -n "${!n:-}" ] && echo "present $n" || echo "FAIL $n missing"; done
# stray spaces/newlines pasted along with the value are the usual mistake
for n in ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD UPDATE_PUSH_SECRET; do v="${!n:-}"; [ "$v" = "$(printf %s "$v" | tr -d ' \r\n\t')" ] || echo "FAIL $n has spaces or line breaks in it"; done
keytool -list -keystore "$K" -storepass "$SP" >/dev/null 2>&1 && echo "PASS keystore opens with ANDROID_KEYSTORE_PASSWORD" || echo "FAIL keystore password wrong (or keystore text damaged)"
keytool -list -keystore "$K" -storepass "$SP" -alias "$AL" >/dev/null 2>&1 && echo "PASS alias found" || echo "FAIL ANDROID_KEY_ALIAS not found in the keystore"
cp "$K" "$K.2"; keytool -keypasswd -keystore "$K.2" -storepass "$SP" -alias "$AL" -keypass "$KP" -new "$KP" >/dev/null 2>&1 && echo "PASS ANDROID_KEY_PASSWORD correct" || echo "FAIL ANDROID_KEY_PASSWORD wrong"
echo "certificate SHA-256 (public):"; keytool -list -v -keystore "$K" -storepass "$SP" -alias "$AL" 2>/dev/null | grep -E "SHA256:|Owner:"
echo "update secret sha256 prefix: $(printf %s "${UPDATE_PUSH_SECRET:-}" | sha256sum | cut -c1-12)"
