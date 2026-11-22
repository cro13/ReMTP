#!/usr/bin/env bash
# Builds an unsigned ReMTP.app and the remtp CLI for one architecture into build/macos-<arch>/:
#   ReMTP.app          with LICENSE.txt and THIRD_PARTY_LICENSES.txt in Contents/Resources
#   cli/remtp          with cli/LICENSE.txt and cli/THIRD_PARTY_LICENSES.txt
# Needs no secrets; signing happens afterwards in sign-macos.sh.
# Usage: scripts/ci/build-macos.sh <arm64|x86_64> <version>
set -euo pipefail
arch="$1"
version="$2"
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/build/macos-$arch"
case "$arch" in arm64) rust_target=aarch64-apple-darwin ;; x86_64) rust_target=x86_64-apple-darwin ;; *) exit 2 ;; esac
rm -rf "$out"
mkdir -p "$out/cli"

"$root/scripts/build-macos-core.sh" --release --arch "$arch"
(cd "$root/apps/macos" && xcodegen generate --quiet)
xcodebuild -project "$root/apps/macos/ReMTP.xcodeproj" -scheme ReMTP -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$out/dd" \
  ARCHS="$arch" ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  CODE_SIGNING_ALLOWED=NO build
cp -R "$out/dd/Build/Products/Release/ReMTP.app" "$out/ReMTP.app"

MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --locked -p remtp-cli --target "$rust_target" --manifest-path "$root/Cargo.toml"
cp "$root/target/$rust_target/release/remtp" "$out/cli/remtp"

# License notices for exactly the crates linked into each binary. They go in before signing, so the
# app's signature covers them.
resources="$out/ReMTP.app/Contents/Resources"
python3 "$root/scripts/third-party-licenses.py" --package remtp-ffi --target "$rust_target" \
  --title ReMTP --output "$resources/THIRD_PARTY_LICENSES.txt"
python3 "$root/scripts/third-party-licenses.py" --package remtp-cli --target "$rust_target" \
  --title "remtp (ReMTP command-line tool)" --output "$out/cli/THIRD_PARTY_LICENSES.txt"
cp "$root/LICENSE" "$resources/LICENSE.txt"
cp "$root/LICENSE" "$out/cli/LICENSE.txt"
echo "Built $out/ReMTP.app and $out/cli/remtp"
