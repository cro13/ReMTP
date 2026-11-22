#!/bin/bash
# verify.sh <label> <devfolder> <expected_count> <expected_size_each>
# Lists <devfolder> on the device with `remtp ls` and checks that it holds exactly
# <expected_count> files of <expected_size_each> bytes and no folders.
# Needs $DEV (remtp device index or id from `remtp devices`) and $S (storage id).
R=${R:-remtp}
L=${L:-./logs}
mkdir -p "$L"
: "${DEV:?DEV not set}" "${S:?S not set}"
label=$1; folder=$2; n=$3; size=$4
"$R" ls "$DEV" "$S" "$folder" > "$L/$label.ls" 2>&1; rc=$?
files=$(awk -F'\t' '$1=="file"' "$L/$label.ls" | wc -l | tr -d ' ')
good=$(awk -F'\t' -v s="$size" '$1=="file" && $2==s' "$L/$label.ls" | wc -l | tr -d ' ')
dirs=$(awk -F'\t' '$1=="dir"' "$L/$label.ls" | wc -l | tr -d ' ')
total=$(awk -F'\t' '$1=="file"{s+=$2} END{printf "%d", s}' "$L/$label.ls")
ok=no; [ $rc -eq 0 ] && [ "$files" = "$n" ] && [ "$good" = "$n" ] && [ "$dirs" = 0 ] && ok=yes
echo "verify label=$label folder=$folder ls_rc=$rc files=$files size_ok=$good dirs=$dirs total_bytes=$total expected=${n}x$size verified=$ok" | tee "$L/$label.verify"
[ "$ok" = yes ]
