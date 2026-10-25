#!/usr/bin/env bash
# Unit tests for disk-safety.sh classify (mock lsblk/pvs/lvs snapshots). Run: ./tests/test-disk-safety.sh
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd); DS="$T/../disk-safety.sh"; F="$T/fixtures"
FSID=11111111-2222-3333-4444-555555555555
pass=0; fail=0
expect() { # snapshot path expected-action [detail-substring]
  local out act
  out=$("$DS" classify "$F/$1" nodeX --fsid "$FSID" "$2" | tail -n1); act=${out%%|*}
  if [ "$act" = "$3" ] && [[ $out == *"${4:-}"* ]]; then pass=$((pass+1)); echo "ok   $1 $2 -> $act"
  else fail=$((fail+1)); echo "FAIL $1 $2 -> $out (want $3 ${4:-})"; fi
}
expect node-a.snap /dev/disk/by-id/ata-SAMSUNG_ROOT REFUSE "backs /"
expect node-a-norootinfo.snap /dev/disk/by-id/ata-SAMSUNG_ROOT REFUSE "mounted: /,/boot,/boot/efi"
expect node-a.snap /dev/disk/by-id/ata-SAMSUNG_ROOT-part3 REFUSE partition
expect node-a.snap /dev/disk/by-id/nvme-CLEAN CREATE clean
expect node-a.snap /dev/disk/by-id/nvme-OLD NEEDS-ZAP xfs
expect node-a.snap /dev/disk/by-id/nvme-OSD SKIP "already an OSD"
expect node-a.snap /dev/disk/by-id/nvme-OTHER REFUSE "another/unknown cluster"
expect node-a.snap /dev/disk/by-id/ata-DATAVG REFUSE "non-Ceph LVM"
expect node-a.snap /dev/disk/by-id/ata-MD REFUSE "md RAID"
expect node-a.snap /dev/disk/by-id/ata-SWAP REFUSE swap
expect node-a.snap /dev/disk/by-id/nvme-MISSING REFUSE "does not resolve"
expect node-a.snap /dev/nvme0n1 REFUSE "not a /dev/disk/by-id"
expect node-md.snap /dev/disk/by-id/ata-MDA REFUSE "backs /"
expect node-md.snap /dev/disk/by-id/ata-MDB REFUSE "backs /"
expect node-md.snap /dev/disk/by-id/md-name-root REFUSE "not a whole disk"
# no fsid known (fresh cluster): any Ceph LVM must be refused, not skipped
out=$("$DS" classify "$F/node-a.snap" nodeX /dev/disk/by-id/nvme-OSD); [[ $out == REFUSE* ]] && { pass=$((pass+1)); echo "ok   no-fsid ceph LVM -> REFUSE"; } || { fail=$((fail+1)); echo "FAIL no-fsid: $out"; }
# duplicate physical disk via two by-id aliases -> both refused
out=$("$DS" classify "$F/node-a.snap" nodeX --fsid "$FSID" /dev/disk/by-id/nvme-CLEAN /dev/disk/by-id/nvme-CLEAN-alias)
[ "$(grep -c '^REFUSE|.*more than once' <<<"$out")" = 2 ] && { pass=$((pass+1)); echo "ok   duplicate -> REFUSE x2"; } || { fail=$((fail+1)); echo "FAIL dup: $out"; }
# confirm gate (add-osds.sh helpers)
. "$T/../add-osds.sh" --source-only
PLAN_TEST=$'CREATE|n1|/dev/disk/by-id/nvme-CLEAN|nvme0n1|1|m|PHLJ0000CLEAN|0|clean\nNEEDS-ZAP|n1|/dev/disk/by-id/nvme-OLD|nvme1n1|1|m|PHLJ0000OLDX|0|x'
c() { FDC_CONFIRM_ALLOW_NONTTY=1 confirm_plan <<<"$PLAN_TEST" 3<<<"$1" >/dev/null 2>&1; }
if c $'YES-WIPE-2\nOLDX'; then pass=$((pass+1)); echo "ok   confirm correct"; else fail=$((fail+1)); echo "FAIL confirm correct"; fi
if c $'YES-WIPE-1\nOLDX'; then fail=$((fail+1)); echo "FAIL wrong N accepted"; else pass=$((pass+1)); echo "ok   wrong N rejected"; fi
if c $'YES-WIPE-2\nXXXX'; then fail=$((fail+1)); echo "FAIL wrong serial accepted"; else pass=$((pass+1)); echo "ok   wrong serial rejected"; fi
if c $'yes'; then fail=$((fail+1)); echo "FAIL 'yes' accepted"; else pass=$((pass+1)); echo "ok   plain yes rejected"; fi
echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
