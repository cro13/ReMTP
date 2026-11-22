#!/usr/bin/env bash
# Imports the Developer ID certificate from CI secrets into a temporary keychain and exports
# SIGNING_IDENTITY to $GITHUB_ENV. Needs MACOS_CERTIFICATE_P12_BASE64 and MACOS_CERTIFICATE_PASSWORD.
set -euo pipefail
keychain="$RUNNER_TEMP/remtp-signing.keychain-db"
password="$(openssl rand -hex 24)"
cert="$RUNNER_TEMP/cert.p12"
trap 'rm -f "$cert"' EXIT

echo "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$cert"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$cert" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

identity="$(security find-identity -v -p codesigning "$keychain" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
[[ -n "$identity" ]] || { echo "No Developer ID Application identity in the certificate" >&2; exit 1; }
echo "SIGNING_IDENTITY=$identity" >> "$GITHUB_ENV"
echo "Imported signing identity: $identity"
