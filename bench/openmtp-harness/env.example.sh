# Copy, fill in, then `source` it in the shell you run the benchmark from.
# R    remtp binary (cargo build --release -p remtp-cli)
# L    log folder        D  local test data (folders A, B, C; see README.md)
# DEV  device index or id from `remtp devices`      S  storage id from `remtp info`
# B    bench folder on the device, /Download/remtp-bench-<UTC timestamp>
export R=../../target/release/remtp L=./logs D=./data DEV=0 S=0x00010001 \
  B=/Download/remtp-bench-$(date -u +%Y%m%dT%H%M%SZ)
export H=$(pwd) T=$(pwd)/timed.sh V=$(pwd)/verify.sh X=$(pwd)/saferm.sh
# Refuse to start while a GUI MTP app holds the device, or if the device is missing.
pre() { if ps -axo command | grep -i -E "/ReMTP.app/|/OpenMTP.app/" | grep -v grep; then echo "APP RUNNING - STOP"; return 1; fi
  "$R" devices | awk -F'\t' -v d="$DEV" '$1==d || $2==d {f=1} END {exit !f}' || { echo "DEVICE $DEV NOT LISTED - STOP"; return 1; }
  echo "pre ok $(date -u +%T)"; }
