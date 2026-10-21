#!/usr/bin/env bash
# Run as root on node1 (NODE_NAMES[0]) after install-node.sh. Idempotent.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root; load_conf
[ "$(self_index)" -eq 0 ] || die "run bootstrap on $ADMIN_NAME only"

if [ -f /etc/ceph/ceph.conf ] && cephadm ls 2>/dev/null | grep -q '"name": "mon\.'; then
  log "cluster already bootstrapped (fsid $(awk '/fsid/ {print $3}' /etc/ceph/ceph.conf)), skipping bootstrap"
else
  curl -fsS "http://$REGISTRY/v2/ceph/ceph/tags/list" | grep -q "v${CEPH_VERSION}" || die "registry has no ceph v$CEPH_VERSION"
  cephadm --image "$CEPH_IMAGE" inspect-image
  ARGS=(--image "$CEPH_IMAGE" bootstrap --mon-ip "$ADMIN_IP"
        --skip-monitoring-stack --skip-dashboard --skip-firewalld
        --allow-fqdn-hostname)
  [ -n "$CLUSTER_NETWORK" ] && ARGS+=(--cluster-network "$CLUSTER_NETWORK")
  log "cephadm ${ARGS[*]}"
  cephadm "${ARGS[@]}" 2>&1 | tee /var/log/fast-deploy-bootstrap.log
fi

log "cluster defaults: size=$POOL_SIZE min_size=$POOL_MIN_SIZE, public_network=$PUBLIC_NETWORK"
ceph_ config set global public_network "$PUBLIC_NETWORK"
ceph_ config set global osd_pool_default_size "$POOL_SIZE"
ceph_ config set global osd_pool_default_min_size "$POOL_MIN_SIZE"
ceph_ config set mgr mgr/cephadm/use_repo_digest true
[ -n "$OSD_MEMORY_TARGET" ] && ceph_ config set osd osd_memory_target "$OSD_MEMORY_TARGET"
ceph_ orch host label add "$ADMIN_NAME" _admin >/dev/null
ceph_ orch host label add "$ADMIN_NAME" mon >/dev/null
ceph_ orch host label add "$ADMIN_NAME" mgr >/dev/null
ceph_ config get mgr container_image
ceph_ -s
log "bootstrap done. Next: distribute /etc/ceph/ceph.pub and add hosts -> ./add-hosts.sh (prints manual commands)"
