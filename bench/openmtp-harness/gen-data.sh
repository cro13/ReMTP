#!/bin/bash
# gen-data.sh [dir]  (default ./data, about 7 GB)
# A = 100 x 30,000,000 B, B = 1,000 x 1,000,000 B, C = 2 x 1,500,000,000 B, all random bytes,
# plus A.sha256 for checking downloads.
set -euo pipefail
D=${1:-./data}
mkdir -p "$D/A" "$D/B" "$D/C"
for i in $(seq -f %03g 0 99); do head -c 30000000 /dev/urandom > "$D/A/a-$i.bin"; done
for i in $(seq -f %04g 0 999); do head -c 1000000 /dev/urandom > "$D/B/b-$i.bin"; done
for i in 0 1; do head -c 1500000000 /dev/urandom > "$D/C/c-$i.bin"; done
(cd "$D/A" && shasum -a 256 *.bin > ../A.sha256)
echo "data ready in $D"
