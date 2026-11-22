#!/usr/bin/env bash
# Signs, notarizes and packages the output of build-macos.sh into dist/:
#   ReMTP-<version>-macos-<arch>.dmg         ReMTP.app, an Applications link, LICENSE.txt, THIRD_PARTY_LICENSES.txt
#   remtp-cli-<version>-macos-<arch>.tar.gz  remtp-cli-<version>-macos-<arch>/{remtp,LICENSE.txt,THIRD_PARTY_LICENSES.txt}
# Signs with $SIGNING_IDENTITY when set (otherwise ad-hoc). Notarizes and staples when NOTARY_KEY_ID,
# NOTARY_ISSUER_ID and NOTARY_KEY_P8_BASE64 are all set (some but not all is an error).
# REQUIRE_NOTARIZATION=1 (tag builds) fails unless the signing identity and all notary credentials are set.
# Usage: scripts/ci/sign-macos.sh <arm64|x86_64> <version>
set -euo pipefail
arch="$1"
version="$2"
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/build/macos-$arch"
dist="$root/dist"
app="$out/ReMTP.app"
cli="$out/cli/remtp"
mkdir -p "$dist"
private="$(mktemp -d)"
trap 'rm -rf "$private"' EXIT

notary_set=0
for v in NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_KEY_P8_BASE64; do [[ -n "${!v:-}" ]] && notary_set=$((notary_set + 1)); done
if [[ $notary_set -ne 0 && $notary_set -ne 3 ]]; then
  echo "Set all of NOTARY_KEY_ID, NOTARY_ISSUER_ID and NOTARY_KEY_P8_BASE64, or none of them." >&2
  exit 1
fi
notarizing=false
[[ $notary_set -eq 3 ]] && notarizing=true
if [[ $notarizing == true && -z "${SIGNING_IDENTITY:-}" ]]; then
  echo "Notarization needs a Developer ID signature: set SIGNING_IDENTITY." >&2
  exit 1
fi
if [[ "${REQUIRE_NOTARIZATION:-}" == 1 && ( -z "${SIGNING_IDENTITY:-}" || $notarizing != true ) ]]; then
  echo "REQUIRE_NOTARIZATION=1: a Developer ID signing identity and all notary credentials are required." >&2
  exit 1
fi
for f in "$app/Contents/Resources/LICENSE.txt" "$app/Contents/Resources/THIRD_PARTY_LICENSES.txt" \
  "$out/cli/LICENSE.txt" "$out/cli/THIRD_PARTY_LICENSES.txt"; do
  [[ -f "$f" ]] || { echo "Missing $f: run scripts/ci/build-macos.sh first." >&2; exit 1; }
done

# Prints a top-level string field of a JSON file, or nothing (plutil prints its errors to stdout).
json_field() {
  local value
  if value="$(plutil -extract "$1" raw -o - "$2" 2>/dev/null)"; then printf '%s' "$value"; fi
}

# Submits a .zip or .dmg and waits. Fails unless Apple accepts it, printing the notary log if not.
notarize() {
  echo "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$private/AuthKey.p8"
  local auth=(--key "$private/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  local result="$private/notary.json" status id
  xcrun notarytool submit "$1" "${auth[@]}" --wait --output-format json > "$result" || true
  cat "$result"; echo
  status="$(json_field status "$result")"
  if [[ "$status" != Accepted ]]; then
    id="$(json_field id "$result")"
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" || true
    rm -f "$private/AuthKey.p8"
    echo "Notarization of $(basename "$1") failed: ${status:-no status}" >&2
    return 1
  fi
  rm -f "$private/AuthKey.p8"
}

entitlements=()
if [[ -f "$root/apps/macos/ReMTP/ReMTP.entitlements" ]]; then
  entitlements=(--entitlements "$root/apps/macos/ReMTP/ReMTP.entitlements")
fi

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp ${entitlements[@]+"${entitlements[@]}"} --sign "$SIGNING_IDENTITY" "$app"
  codesign --verify --strict --verbose=2 "$app"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$cli"
  codesign --verify --strict --verbose=2 "$cli"
  if [[ $notarizing == true ]]; then
    # One submission for both: tickets are issued per code signature, so the app can be stapled
    # afterwards. A bare Mach-O can't be stapled; Gatekeeper checks the CLI's ticket online.
    ditto "$app" "$private/notarize/ReMTP.app"
    ditto "$cli" "$private/notarize/remtp"
    ditto -c -k "$private/notarize" "$private/ReMTP-notarize.zip"
    notarize "$private/ReMTP-notarize.zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute -vv "$app"
  fi
else
  codesign --force --deep --sign - "$app"
  codesign --force --sign - "$cli"
fi

staging="$private/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
cp "$app/Contents/Resources/LICENSE.txt" "$app/Contents/Resources/THIRD_PARTY_LICENSES.txt" "$staging/"
dmg="$dist/ReMTP-$version-macos-$arch.dmg"
hdiutil create -volname "ReMTP $version" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$dmg"
  codesign --verify --strict --verbose=2 "$dmg"
  if [[ $notarizing == true ]]; then
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature -vv "$dmg"
  fi
fi

cli_dir="remtp-cli-$version-macos-$arch"
mkdir -p "$private/$cli_dir"
cp "$cli" "$out/cli/LICENSE.txt" "$out/cli/THIRD_PARTY_LICENSES.txt" "$private/$cli_dir/"
tar -czf "$dist/$cli_dir.tar.gz" -C "$private" "$cli_dir"
ls -la "$dist"
