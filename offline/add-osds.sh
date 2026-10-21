#!/usr/bin/env bash
# Run on node1. Creates one OSD per device listed in OSD_DEVICES (by-id paths).
#   ./add-osds.sh                           # PREVIEW only (no changes)
#   ./add-osds.sh --yes-i-really-mean-it    # wipe+create OSDs (skips devices already OSDs)
#   ./add-osds.sh --host node2 [...]        # limit to one host
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root; load_conf
CONFIRM=0; ONLY=""
while [ $# -gt 0 ]; do
  case $1 in
    --yes-i-really-mean-it) CONFIRM=1;;
    --host) ONLY=$2; shift;;
    *) die "unknown arg $1";;
  esac; shift
done

[ "${#OSD_DEVICES[@]}" -gt 0 ] || die "OSD_DEVICES empty"
log "orchestrator device inventory:"
ceph_ orch device ls --wide --refresh || true
OSDMETA=$(ceph_ osd metadata --format json 2>/dev/null || echo '[]')

printf '\n%-10s %-60s %s\n' HOST DEVICE ACTION
PLAN=()
for e in "${OSD_DEVICES[@]}"; do
  h=${e%%:*}; d=${e#*:}
  [ -n "$ONLY" ] && [ "$h" != "$ONLY" ] && continue
  [[ $d == /dev/disk/by-id/* || $d == /dev/disk/by-path/* ]] || warn "$e: not a stable by-id path"
  # resolve on the target host to detect existing OSD by kernel name
  # resolve the by-id link on the target host (local, or via root ssh if available)
  if [ "$h" = "$(hostname -s)" ]; then
    base=$(readlink -e "$d" || true)
  else
    base=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$h" "readlink -e $d" 2>/dev/null || true)
  fi
  if [ -z "$base" ]; then
    printf '%-10s %-60s %s\n' "$h" "$d" "CREATE OSD (not resolvable from here; ceph-volume refuses in-use disks)"
    PLAN+=("$h:$d"); continue
  fi
  kn=$(basename "$base")
  if echo "$OSDMETA" | jq -e --arg h "$h" --arg k "$kn" '.[] | select(.hostname==$h) | select((.devices // "") | split(",") | index($k))' >/dev/null 2>&1; then
    printf '%-10s %-60s %s\n' "$h" "$d" "skip (already OSD on $kn)"
  else
    printf '%-10s %-60s %s\n' "$h" "$d" "CREATE OSD (wipes $kn)"
    PLAN+=("$h:$d")
  fi
done
echo
if [ "$CONFIRM" -eq 0 ]; then
  log "PREVIEW only. ${#PLAN[@]} OSD(s) would be created. Re-run with --yes-i-really-mean-it"
  exit 0
fi
for p in "${PLAN[@]}"; do
  log "ceph orch daemon add osd $p"
  ceph_ orch daemon add osd "$p"
done
ceph_ osd tree
ceph_ osd stat
