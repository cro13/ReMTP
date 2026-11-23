#!/usr/bin/env bash
# Writes the app's own screens (main window, transfers, inspector, device access; light and dark) to
# design/screenshots/ from a Debug build running the demo backend, shown as the app ships (no Sync, no DEMO
# badge, home folder labelled "Home"). The app draws its own window, so no Screen Recording permission is
# needed. Build the app first (apps/macos/README.md), or pass ReMTP.app: design/app-shots.sh path/to/ReMTP.app
# Exits non-zero if the app reports a FAIL or a screen is missing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="${1:-$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/ReMTP-*/Build/Products/Debug/ReMTP.app 2>/dev/null | head -1 || true)}"
[ -x "$app/Contents/MacOS/ReMTP" ] || { echo "Build the Debug app first, or pass the path to ReMTP.app." >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The Mac pane's folder: sample files and the demo's (sparse) copies go here.
mkdir -p "$work/Pictures/Lisbon 2026" "$work/shots"
# Keep other apps out of the front while it runs: a window that loses focus is shot greyed out (reported as FAIL).
# The screens need a 2x display (CI adds a virtual one) and come out the same on every Mac and run: English with
# British dates and 24-hour times, Zurich time, scroll bars always shown, and the demo's clock pinned to
# 21 Nov 2026, 22:32 (REMTP_DEMO_NOW, seconds since 1970).
TZ=Europe/Zurich REMTP_DEMO_NOW=1795296720 \
  REMTP_SNAPSHOT_SCREENS=1 REMTP_SNAPSHOT_DIR="$work/shots" REMTP_SNAPSHOT_MAC_PATH="$work/Pictures/Lisbon 2026" \
  "$app/Contents/MacOS/ReMTP" -AppleLanguages '(en)' -AppleLocale en_GB -AppleShowScrollBars Always
# The canonical set the README and docs use; the run also writes extra screens, which are left out.
shots=()
for name in 01-main 03-transfers 05-inspector 06-access; do
  for theme in light dark; do shots+=("$name-$theme.png"); done
done
for shot in "${shots[@]}"; do
  [ -s "$work/shots/$shot" ] || { echo "Missing $shot" >&2; exit 1; }
done
mkdir -p "$here/screenshots"
for shot in "${shots[@]}"; do
  cp "$work/shots/$shot" "$here/screenshots/"
  echo "$here/screenshots/$shot"
done
