#!/usr/bin/env bash
# Run on node1 after OSDs are up. Idempotent. Aligns .mgr to POOL_SIZE and creates the RBD
# pools from RBD_POOLS ("name:pg_num:size:target_size_ratio"), rbd pool init + app enable.
#   sudo ./setup-pools.sh [--dry-run]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
for a in "$@"; do case $a in --dry-run) DRY_RUN=1;; *) die "unknown arg $a";; esac; done
[ "$DRY_RUN" = 1 ] || need_root
load_conf
[ "${#RBD_POOLS[@]}" -gt 0 ] || { log "RBD_POOLS empty, nothing to do"; exit 0; }

pool_exists() { [ "$DRY_RUN" = 1 ] && return 1; ceph_ osd pool ls | grep -qx "$1"; }
set_size() { # pool size min
  if [ "$2" -eq 1 ]; then
    run ceph_ config set global mon_allow_pool_size_one true
    run ceph_ osd pool set "$1" size 1 --yes-i-really-mean-it
  else
    run ceph_ osd pool set "$1" size "$2"
  fi
  run ceph_ osd pool set "$1" min_size "$3"
}

if [ "$POOL_SIZE" -gt 1 ]; then set_size .mgr "$POOL_SIZE" "$POOL_MIN_SIZE"; fi
for e in "${RBD_POOLS[@]}"; do
  IFS=: read -r name pg size ratio <<<"$e"
  size=${size:-$POOL_SIZE}; pg=${pg:-32}
  if [ "$size" -ge 3 ]; then min=$(( POOL_MIN_SIZE < size ? POOL_MIN_SIZE : size - 1 )); else min=1; fi
  log "pool $name pg=$pg size=$size min_size=$min autoscale=$PG_AUTOSCALE ratio=${ratio:-none}"
  if pool_exists "$name"; then log "  exists"; else run ceph_ osd pool create "$name" "$pg" "$pg" replicated; fi
  set_size "$name" "$size" "$min"
  run ceph_ osd pool set "$name" pg_autoscale_mode "$PG_AUTOSCALE"
  [ -n "${ratio:-}" ] && run ceph_ osd pool set "$name" target_size_ratio "$ratio"
  run ceph_ osd pool application enable "$name" rbd
  run cephadm shell -- rbd pool init "$name" </dev/null
done
[ "$DRY_RUN" = 1 ] || ceph_ osd pool ls detail
log "setup-pools.sh done"
