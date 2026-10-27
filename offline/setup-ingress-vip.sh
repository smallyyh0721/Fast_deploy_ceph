#!/usr/bin/env bash
# Configure cephadm ingress VIP (haproxy + keepalived containers from local registry).
# Default: print YAML + commands only. Pass --apply to set image pins and orch apply.
#
#   sudo ./setup-ingress-vip.sh              # preview
#   sudo ./setup-ingress-vip.sh --apply      # write mgr image config + apply ingress
#
# Prerequisites: 3 hosts with mon (or chosen backend) already deployed; VIP_ADDR set
# in cluster.conf (placeholders OK until real cutover). Run on node1 only.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root; load_conf
[ "$(self_index)" -eq 0 ] || die "run setup-ingress-vip on $ADMIN_NAME only"

APPLY=0
for a in "$@"; do
  case $a in
    --apply) APPLY=1;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) die "unknown arg $a (use --apply or no args for preview)";;
  esac
done

[ -n "$VIP_ADDR" ] || die "VIP_ADDR empty in cluster.conf (placeholder e.g. 10.250.0.10)"
[[ "$VIP_ADDR" != */* ]] || die "VIP_ADDR must be bare IP; put prefix in VIP_CIDR"
VIP_CIDR_SPEC="${VIP_ADDR}/${VIP_CIDR}"
[ -n "$VIP_INTERFACE_NETWORK" ] || die "VIP_INTERFACE_NETWORK empty (usually PUBLIC_NETWORK)"

# placement: all cluster nodes (ingress on every mon host)
PLACEMENT_HOSTS=$(printf '%s\n' "${NODE_NAMES[@]}" | sed 's/^/    - /')

SPEC_FILE=$(mktemp /tmp/ingress-vip.XXXXXX.yaml)
cleanup() { rm -f "$SPEC_FILE"; }
trap cleanup EXIT

{
  echo "service_type: ingress"
  echo "service_id: ${INGRESS_SERVICE_ID}"
  echo "placement:"
  echo "  hosts:"
  echo "$PLACEMENT_HOSTS"
  echo "spec:"
  echo "  backend_service: ${INGRESS_BACKEND_SERVICE}"
  echo "  virtual_ip: ${VIP_CIDR_SPEC}"
  echo "  virtual_interface_networks:"
  echo "    - ${VIP_INTERFACE_NETWORK}"
  if [ -n "${VRRP_INTERFACE_NETWORK}" ]; then
    echo "  vrrp_interface_network: ${VRRP_INTERFACE_NETWORK}"
  fi
  if [ "${INGRESS_KEEPALIVE_ONLY}" = "1" ]; then
    echo "  keepalive_only: true"
  else
    echo "  frontend_port: ${INGRESS_FRONTEND_PORT}"
    echo "  monitor_port: ${INGRESS_MONITOR_PORT}"
  fi
} > "$SPEC_FILE"

log "ingress images (local registry)"
echo "  haproxy:    $HAPROXY_IMAGE  (src $HAPROXY_IMAGE_SRC)"
echo "  keepalived: $KEEPALIVED_IMAGE  (src $KEEPALIVED_IMAGE_SRC)"
log "generated spec ($SPEC_FILE):"
cat "$SPEC_FILE"
echo
if [ "${INGRESS_KEEPALIVE_ONLY}" = "1" ]; then
  warn "INGRESS_KEEPALIVE_ONLY=1: keepalived VIP only (no haproxy). Recommended for backend_service=mon on Tentacle 20.2.4 (stock ingress haproxy uses HTTP for non-nfs backends)."
  warn "CSI monitors: prefer all MON IPs (${NODE_IPS[*]}:3300). VIP alone does not make mon listen on ${VIP_ADDR}; use VIP as an extra endpoint only after you verify reachability."
else
  warn "Full haproxy+keepalived. Suitable for RGW/NFS backends. For mon msgr2, Tentacle forces HTTP mode — verify before production CSI."
fi

echo
echo "=== commands that --apply will run ==="
echo "cephadm shell -- ceph config set mgr mgr/cephadm/container_image_haproxy $HAPROXY_IMAGE"
echo "cephadm shell -- ceph config set mgr mgr/cephadm/container_image_keepalived $KEEPALIVED_IMAGE"
echo "cephadm shell -- ceph config set mgr mgr/cephadm/use_repo_digest true"
echo "cephadm shell -- ceph orch apply -i <spec>"
echo "cephadm shell -- ceph orch ps --service-name ingress.${INGRESS_SERVICE_ID}"
echo "cephadm shell -- ceph orch ls ingress"
echo

if [ "$APPLY" -eq 0 ]; then
  log "preview only. Re-run with --apply after editing VIP_* in cluster.conf."
  exit 0
fi

# Ensure images are in registry (admin node already ran install-node.sh)
curl -fsS "http://$REGISTRY/v2/ceph/haproxy/tags/list" | grep -q "$HAPROXY_TAG" \
  || die "registry missing haproxy:$HAPROXY_TAG — re-run install-node.sh on $ADMIN_NAME"
curl -fsS "http://$REGISTRY/v2/ceph/keepalived/tags/list" | grep -q "$KEEPALIVED_TAG" \
  || die "registry missing keepalived:$KEEPALIVED_TAG — re-run install-node.sh on $ADMIN_NAME"

log "pin cephadm ingress images to local registry"
ceph_ config set mgr mgr/cephadm/container_image_haproxy "$HAPROXY_IMAGE"
ceph_ config set mgr mgr/cephadm/container_image_keepalived "$KEEPALIVED_IMAGE"
ceph_ config set mgr mgr/cephadm/use_repo_digest true

log "ceph orch apply -i ingress spec"
cephadm shell -m "$SPEC_FILE":/tmp/ingress.yaml -- ceph orch apply -i /tmp/ingress.yaml </dev/null

log "wait briefly and show daemons"
sleep 3
ceph_ orch ls ingress || true
ceph_ orch ps --service-name "ingress.${INGRESS_SERVICE_ID}" || true
log "check VIP on nodes: ip -br addr | grep ${VIP_ADDR}"
log "setup-ingress-vip.sh --apply done"
