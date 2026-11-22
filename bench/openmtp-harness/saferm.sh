#!/bin/bash
# saferm.sh <label> <devpath>
# Deletes <devpath> on the device ($DEV, $S) with `remtp rm`, only if it is the run's bench folder
# ($B, which must look like /Download/remtp-bench-YYYYMMDDTHHMMSSZ) or a path inside it.
# Lists it first; timed via timed.sh.
R=${R:-remtp}
L=${L:-./logs}
here=$(cd "$(dirname "$0")" && pwd)
: "${DEV:?}" "${S:?}" "${B:?}"
label=$1; p=$2
[[ "$B" =~ ^/Download/remtp-bench-[0-9]{8}T[0-9]{6}Z$ ]] || { echo "REFUSE: bad B=$B"; exit 9; }
[[ "$p" == "$B" || "$p" == "$B/"* ]] || { echo "REFUSE: $p not inside $B"; exit 9; }
[[ "$p" != *".."* ]] || { echo "REFUSE: .. in $p"; exit 9; }
mkdir -p "$L"
"$R" ls "$DEV" "$S" "$p" > "$L/$label.prelist" 2>&1
echo "prelist $p: $(awk -F'\t' '$1=="file"' "$L/$label.prelist" | wc -l | tr -d ' ') files, $(awk -F'\t' '$1=="dir"' "$L/$label.prelist" | wc -l | tr -d ' ') dirs"
"$here/timed.sh" "$label" 900 "$R" rm "$DEV" "$S" "$p"
rc=$?
cat "$L/$label.err"
exit "$rc"
