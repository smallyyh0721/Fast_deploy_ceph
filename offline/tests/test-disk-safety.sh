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
# ---- probe / ssh helpers (issue #1): no bash -s stream; ssh -n; strict host-key knobs ----
AO="$T/../add-osds.sh"; LIB="$T/../lib.sh"
# remote probe must scp + execute by path, never stream script via bash -s
if grep -E 'bash[[:space:]]+-s' "$AO" | grep -qvE '^[[:space:]]*#'; then
  fail=$((fail+1)); echo "FAIL add-osds still uses bash -s for remote probe"
else pass=$((pass+1)); echo "ok   probe does not use bash -s"; fi
grep -q 'scp .*disk-safety.sh' "$AO" && grep -q 'REMOTE_DISK_SAFETY\|offline/disk-safety.sh' "$AO" \
  && { pass=$((pass+1)); echo "ok   probe scp + remote path"; } \
  || { fail=$((fail+1)); echo "FAIL probe missing scp/remote path"; }
# ssh_node closes stdin; ssh_node_in exists for rare streaming callers
grep -qE 'ssh_node\(\).*ssh -n|ssh -n "\$\{SSH_OPTS' "$LIB" \
  && { pass=$((pass+1)); echo "ok   ssh_node uses ssh -n"; } \
  || { fail=$((fail+1)); echo "FAIL ssh_node missing -n"; }
grep -q 'ssh_node_in()' "$LIB" \
  && { pass=$((pass+1)); echo "ok   ssh_node_in present"; } \
  || { fail=$((fail+1)); echo "FAIL ssh_node_in missing"; }
# ceph_ closes stdin so apply-plan cannot be drained
grep -q 'cephadm shell -- ceph "$@" </dev/null' "$LIB" \
  && { pass=$((pass+1)); echo "ok   ceph_ closes stdin"; } \
  || { fail=$((fail+1)); echo "FAIL ceph_ stdin not closed"; }
# ssh_build_opts: default accept-new; strict + known_hosts when set
W=$(mktemp -d); trap 'rm -rf "$W"' RETURN
cat > "$W/c.conf" <<'C'
NODE_NAMES=(node1); NODE_IPS=(127.0.0.1); PUBLIC_NETWORK=127.0.0.0/8
CEPH_VERSION=20.2.4; REGISTRY_PORT=5000; BUNDLE_DIR=/opt/ceph-offline
OSD_DEVICES=("node1:/dev/disk/by-id/x"); POOL_SIZE=1; POOL_MIN_SIZE=1
C
opts_of() { # print SSH_OPTS joined
  env -i PATH="$PATH" HOME="$HOME" CONF="$W/c.conf" bash -c '
    set -euo pipefail
    . "'"$LIB"'"
    '"$1"'
    load_conf
    printf "%s\n" "${SSH_OPTS[*]}"
  '
}
o=$(opts_of ''); [[ $o == *StrictHostKeyChecking=accept-new* ]] \
  && { pass=$((pass+1)); echo "ok   default accept-new"; } \
  || { fail=$((fail+1)); echo "FAIL default opts: $o"; }
o=$(opts_of 'SSH_STRICT_HOSTKEY=1; SSH_KNOWN_HOSTS=/tmp/kh.test')
[[ $o == *StrictHostKeyChecking=yes* && $o == *UserKnownHostsFile=/tmp/kh.test* && $o != *accept-new* ]] \
  && { pass=$((pass+1)); echo "ok   strict + UserKnownHostsFile"; } \
  || { fail=$((fail+1)); echo "FAIL strict opts: $o"; }
# conf file knobs
cat >> "$W/c.conf" <<'C'
SSH_STRICT_HOSTKEY=1
SSH_KNOWN_HOSTS=/etc/fast-deploy/known_hosts
C
o=$(opts_of '')
[[ $o == *StrictHostKeyChecking=yes* && $o == *UserKnownHostsFile=/etc/fast-deploy/known_hosts* ]] \
  && { pass=$((pass+1)); echo "ok   conf SSH_STRICT_HOSTKEY/SSH_KNOWN_HOSTS"; } \
  || { fail=$((fail+1)); echo "FAIL conf opts: $o"; }
# deploy install stage uses ssh_node (closed stdin), not bare ssh without -n
if grep -E 'run ssh "\$\{SSH_OPTS' "$T/../deploy.sh" | grep -qvE '^[[:space:]]*#'; then
  fail=$((fail+1)); echo "FAIL deploy.sh still uses ssh without ssh_node/-n"
else pass=$((pass+1)); echo "ok   deploy install uses ssh_node"; fi
echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
