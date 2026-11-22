#!/bin/bash
# timed.sh <label> <timeout_s> <cmd...>
# Runs cmd, records wall time (process start -> exit), exit code, stdout/stderr in $L/<label>.*
# Kills the command if it runs longer than timeout_s (hang guard).
label=$1; limit=$2; shift 2
L=${L:-./logs}
mkdir -p "$L"
ts() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
echo "$*" > "$L/$label.cmd"
t0=$(ts)
"$@" > "$L/$label.out" 2> "$L/$label.err" &
pid=$!
killed=0
while kill -0 $pid 2>/dev/null; do
  sleep 0.2
  if perl -e "exit(!($(ts) - $t0 > $limit))"; then echo "TIMEOUT after ${limit}s, killing" >> "$L/$label.err"; kill -INT $pid; sleep 10; kill -9 $pid 2>/dev/null; killed=1; break; fi
done
wait $pid; rc=$?
t1=$(ts)
wall=$(perl -e "printf '%.3f', $t1 - $t0")
echo "label=$label rc=$rc killed=$killed wall_s=$wall start=$t0 end=$t1" | tee "$L/$label.time"
# Exit with the command's status (124 if it was killed), so callers can stop on a failed run.
[ "$killed" = 1 ] && exit 124
exit "$rc"
