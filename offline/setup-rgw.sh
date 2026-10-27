#!/usr/bin/env bash
# Run on node1. Idempotent. RGW (S3) with realm/zonegroup/zone (master, default), service
# rgw.$RGW_SERVICE_ID on hosts labelled "rgw" (RGW_HOSTS), and — if RGW_INGRESS=1 — its own
# VIP via cephadm ingress (haproxy + keepalived from the local registry).
#   sudo ./setup-rgw.sh [--dry-run]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
for a in "$@"; do case $a in --dry-run) DRY_RUN=1;; *) die "unknown arg $a";; esac; done
[ "$DRY_RUN" = 1 ] || need_root
load_conf
[ "${#RGW_HOSTS[@]}" -gt 0 ] || die "RGW_HOSTS empty"
SVC="rgw.${RGW_SERVICE_ID}"
rgwadm() { cephadm shell -- radosgw-admin "$@" </dev/null; }   # stdin closed (cephadm shell drains it)
have() { [ "$DRY_RUN" = 1 ] && return 1; rgwadm "$1" list 2>/dev/null | jq -e --arg n "$2" '(.realms // .zonegroups // .zones // []) | index($n)' >/dev/null; }

log "labels rgw -> ${RGW_HOSTS[*]}"
for h in "${RGW_HOSTS[@]}"; do run ceph_ orch host label add "$h" rgw; done

log "realm/zonegroup/zone: $RGW_REALM / $RGW_ZONEGROUP / $RGW_ZONE"
CHANGED=0
have realm "$RGW_REALM" || { run rgwadm realm create --rgw-realm="$RGW_REALM" --default; CHANGED=1; }
have zonegroup "$RGW_ZONEGROUP" || { run rgwadm zonegroup create --rgw-zonegroup="$RGW_ZONEGROUP" --rgw-realm="$RGW_REALM" --master --default; CHANGED=1; }
have zone "$RGW_ZONE" || { run rgwadm zone create --rgw-zonegroup="$RGW_ZONEGROUP" --rgw-zone="$RGW_ZONE" --master --default; CHANGED=1; }
[ "$CHANGED" = 1 ] && run rgwadm period update --rgw-realm="$RGW_REALM" --commit

# pre-create the data pool so pg_num/size follow cluster.conf (rgw creates the rest itself)
DP="${RGW_ZONE}.rgw.buckets.data"
if [ "$DRY_RUN" = 1 ] || ! ceph_ osd pool ls | grep -qx "$DP"; then
  run ceph_ osd pool create "$DP" "$RGW_DATA_PG" "$RGW_DATA_PG" replicated
  run ceph_ osd pool application enable "$DP" rgw
fi

log "orch apply $SVC on label:rgw port $RGW_PORT"
run ceph_ orch apply rgw "$RGW_SERVICE_ID" --realm="$RGW_REALM" --zonegroup="$RGW_ZONEGROUP" --zone="$RGW_ZONE" \
  --placement="${#RGW_HOSTS[@]} label:rgw" --port="$RGW_PORT"

if [ "$RGW_INGRESS" = 1 ]; then
  [ -n "$RGW_VIP" ] || die "RGW_INGRESS=1 but RGW_VIP empty"
  [[ $RGW_VIP != */* ]] || die "RGW_VIP must be a bare IP; prefix goes to RGW_VIP_CIDR"
  [ "$RGW_VIP" != "${VIP_ADDR:-}" ] || [ "$ENABLE_MON_VIP" != 1 ] || die "RGW_VIP must differ from mon VIP_ADDR"
  SPEC=$(mktemp /tmp/rgw-ingress.XXXXXX.yaml); trap 'rm -f "$SPEC"' EXIT
  {
    echo "service_type: ingress"
    echo "service_id: ${SVC}"
    echo "placement:"
    echo "  count: ${#RGW_HOSTS[@]}"
    echo "  label: rgw"
    echo "spec:"
    echo "  backend_service: ${SVC}"
    echo "  virtual_ip: ${RGW_VIP}/${RGW_VIP_CIDR}"
    echo "  virtual_interface_networks:"
    echo "    - ${RGW_VIP_INTERFACE_NETWORK}"
    echo "  frontend_port: ${RGW_FRONTEND_PORT}"
    echo "  monitor_port: ${RGW_MONITOR_PORT}"
    echo "  first_virtual_router_id: ${RGW_VRRP_ROUTER_ID}"
  } > "$SPEC"
  log "RGW ingress spec:"; cat "$SPEC"
  if [ "$DRY_RUN" != 1 ]; then
    curl -fsS "http://$REGISTRY/v2/ceph/haproxy/tags/list" | grep -q "$HAPROXY_TAG" || die "registry missing haproxy:$HAPROXY_TAG (re-run install-node.sh on $ADMIN_NAME)"
    curl -fsS "http://$REGISTRY/v2/ceph/keepalived/tags/list" | grep -q "$KEEPALIVED_TAG" || die "registry missing keepalived:$KEEPALIVED_TAG"
  fi
  run ceph_ config set mgr mgr/cephadm/container_image_haproxy "$HAPROXY_IMAGE"
  run ceph_ config set mgr mgr/cephadm/container_image_keepalived "$KEEPALIVED_IMAGE"
  run cephadm shell -m "$SPEC":/tmp/rgw-ingress.yaml -- ceph orch apply -i /tmp/rgw-ingress.yaml </dev/null
  EP="http://${RGW_VIP}:${RGW_FRONTEND_PORT}"
else
  EP="http://$(node_ip "${RGW_HOSTS[0]}"):${RGW_PORT}"
fi
[ "$DRY_RUN" = 1 ] || { sleep 3; ceph_ orch ls rgw || true; ceph_ orch ps --daemon-type rgw || true; }
log "S3 endpoint: $EP   (create users: cephadm shell -- radosgw-admin user create --uid=<u> --display-name=<n>)"
