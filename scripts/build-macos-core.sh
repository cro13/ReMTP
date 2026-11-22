#!/usr/bin/env bash
# Builds remtp-ffi for macOS, generates the Swift bindings into apps/macos/Generated and packages the
# static library as apps/macos/Frameworks/RemtpFFI.xcframework.
# Usage: scripts/build-macos-core.sh [--release] [--arch arm64|x86_64]...   (default: this Mac's arch, debug)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
profile=debug
archs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) profile=release ;;
    --arch) archs+=("$2"); shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ ${#archs[@]} -gt 0 ]] || archs=("$(uname -m)")

targets=()
for a in "${archs[@]}"; do
  case "$a" in
    arm64 | aarch64) targets+=(aarch64-apple-darwin) ;;
    x86_64) targets+=(x86_64-apple-darwin) ;;
    *) echo "unsupported arch: $a" >&2; exit 2 ;;
  esac
done

export MACOSX_DEPLOYMENT_TARGET=14.0
cargo_flags=(--manifest-path "$root/Cargo.toml" --locked)
[[ $profile == release ]] && cargo_flags+=(--release)
for t in "${targets[@]}"; do
  rustup target add "$t" >/dev/null
  cargo build -p remtp-ffi --lib --target "$t" "${cargo_flags[@]}"
done

gen="$root/apps/macos/Generated"
fw="$root/apps/macos/Frameworks"
work="$root/build/ffi"
rm -rf "$gen" "$fw/RemtpFFI.xcframework" "$work"
mkdir -p "$gen" "$fw" "$work/headers"

cargo run -q -p remtp-ffi --features cli --bin uniffi-bindgen --manifest-path "$root/Cargo.toml" --locked -- \
  generate --library "$root/target/${targets[0]}/$profile/libremtp_ffi.dylib" --language swift --out-dir "$work/bindings"
cp "$work/bindings/"*.swift "$gen/"
cp "$work/bindings/"*.h "$work/headers/"
cat "$work/bindings/"*.modulemap > "$work/headers/module.modulemap"

libs=()
for t in "${targets[@]}"; do libs+=("$root/target/$t/$profile/libremtp_ffi.a"); done
lipo -create "${libs[@]}" -output "$work/libremtp_ffi.a"
xcodebuild -create-xcframework -library "$work/libremtp_ffi.a" -headers "$work/headers" -output "$fw/RemtpFFI.xcframework" >/dev/null
echo "Built RemtpFFI.xcframework (${targets[*]}, $profile) and $(ls "$gen")"
