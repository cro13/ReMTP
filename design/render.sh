#!/usr/bin/env bash
# Renders the mockup screens the app doesn't have yet (sync, Windows) in light and dark to
# design/mockup/renders/ with headless Chrome. They are design mockups, not the app: design/screenshots/ holds
# only shots of the app itself (see design/app-shots.sh).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
profile="$(mktemp -d)"
trap 'rm -rf "$profile"' EXIT
mkdir -p "$here/mockup/renders"
for entry in 04:sync 07:windows; do
  n="${entry%%:*}" s="${entry#*:}"
  for t in light dark; do
    out="$here/mockup/renders/${n}-${s}-${t}.png"
    "$chrome" --headless=new --user-data-dir="$profile" --hide-scrollbars --force-device-scale-factor=2 \
      --window-size=1560,980 --virtual-time-budget=2000 --screenshot="$out" \
      "file://$here/mockup/index.html?screen=$s&theme=$t&shot=1" >/dev/null 2>&1
    echo "$out"
  done
done
