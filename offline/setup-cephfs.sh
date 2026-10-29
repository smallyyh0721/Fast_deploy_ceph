#!/usr/bin/env bash
# Run on node1 after OSDs are up. Creates pools (size from config), CephFS, MDS active+standby,
# and client keys. Idempotent.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root; load_conf

UP=$(ceph_ osd stat --format json | jq .num_up_osds)
HOSTS=$(ceph_ osd tree --format json | jq '[.nodes[] | select(.type=="host")] | length')
log "up OSDs: $UP, OSD hosts: $HOSTS, requested size=$POOL_SIZE min_size=$POOL_MIN_SIZE"
[ "$HOSTS" -ge "$POOL_SIZE" ] || warn "fewer OSD hosts ($HOSTS) than POOL_SIZE ($POOL_SIZE): PGs will stay undersized (crush failure domain = host)"

# bootstrap creates .mgr before osd_pool_default_size is set: align it
if [ "$POOL_SIZE" -gt 1 ]; then ceph_ osd pool set .mgr size "$POOL_SIZE"; ceph_ osd pool set .mgr min_size "$POOL_MIN_SIZE"; fi
for p in "$META_POOL:$META_PG" "$DATA_POOL:$DATA_PG"; do
  n=${p%%:*}; pg=${p#*:}
  ceph_ osd pool ls | grep -qx "$n" || ceph_ osd pool create "$n" "$pg"
  if [ "$POOL_SIZE" -eq 1 ]; then
    ceph_ config set global mon_allow_pool_size_one true
    ceph_ osd pool set "$n" size 1 --yes-i-really-mean-it
  else
    ceph_ osd pool set "$n" size "$POOL_SIZE"
  fi
  ceph_ osd pool set "$n" min_size "$POOL_MIN_SIZE"
done
ceph_ fs ls --format json | jq -e --arg f "$FS_NAME" '.[] | select(.name==$f)' >/dev/null \
  || ceph_ fs new "$FS_NAME" "$META_POOL" "$DATA_POOL"
if [ "${#MDS_HOSTS[@]}" -gt 0 ]; then
  for h in "${MDS_HOSTS[@]}"; do ceph_ orch host label add "$h" mds >/dev/null; done
  ceph_ orch apply mds "$FS_NAME" --placement="$MDS_COUNT label:mds"
else
  ceph_ orch apply mds "$FS_NAME" --placement="$MDS_COUNT"
fi
ceph_ fs set "$FS_NAME" max_mds 1
ceph_ auth get "client.$CLIENT_RO" >/dev/null 2>&1 || ceph_ fs authorize "$FS_NAME" "client.$CLIENT_RO" / r
ceph_ auth get "client.$CLIENT_RW" >/dev/null 2>&1 || ceph_ fs authorize "$FS_NAME" "client.$CLIENT_RW" / rw
install -d -m 700 /root/ceph-client-secrets
for c in "$CLIENT_RO" "$CLIENT_RW"; do
  ceph_ auth get-key "client.$c" > "/root/ceph-client-secrets/$c.secret"
  chmod 600 "/root/ceph-client-secrets/$c.secret"
done
ceph_ osd pool ls detail
ceph_ fs status "$FS_NAME"

# Ubuntu 24.04 kernel 6.8 rejects kernel CephFS/krbd secrets ("libceph: secret too big 32").
# ceph-fuse uses librados. The bundle ships ceph-fuse; fuse3's fusermount is enough, so a
# conflict between the transitional fuse package and fuse3 must not fail this stage.
DEB_DIR=$(cd "$HERE/.." && pwd)/debs
if ! command -v ceph-fuse >/dev/null 2>&1; then
  lib_deb=$(ls "$DEB_DIR"/libfuse2t64_*.deb 2>/dev/null | head -1 || true)
  fuse_deb=$(ls "$DEB_DIR"/ceph-fuse_*.deb 2>/dev/null | head -1 || true)
  if [ -n "$fuse_deb" ]; then
    [ -n "$lib_deb" ] && dpkg -i "$lib_deb" >/dev/null 2>&1 || true
    if dpkg -i "$fuse_deb"; then
      log "installed $(basename "$fuse_deb")"
    else
      warn "dpkg -i $(basename "$fuse_deb") failed"
    fi
  else
    warn "ceph-fuse deb not in $DEB_DIR; kernel mount -t ceph will fail on Ubuntu 24.04 kernel 6.8"
  fi
fi
mon_addrs=()
for ip in "${NODE_IPS[@]:0:3}"; do mon_addrs+=("${ip}:3300"); done
MON_ADDRS=$(IFS=,; echo "${mon_addrs[*]}")
log "client mount uses ceph-fuse (raw key file, mode 600, under /root/ceph-client-secrets/):"
echo "ceph-fuse -n client.${CLIENT_RO} --keyfile /root/ceph-client-secrets/${CLIENT_RO}.secret -m ${MON_ADDRS} --client_fs ${FS_NAME} /mnt/${FS_NAME}"
warn "do not use mount -t ceph on Ubuntu 24.04 kernel 6.8: dmesg shows libceph: secret too big 32"
