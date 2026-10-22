#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts.
# shellcheck disable=SC2034
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF=${CONF:-$HERE/cluster.conf}

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%T)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

load_conf() {
  [ -f "$CONF" ] || die "config $CONF not found (cp cluster.conf.example cluster.conf)"
  # shellcheck source=/dev/null
  . "$CONF"
  [ "${#NODE_NAMES[@]}" -eq "${#NODE_IPS[@]}" ] || die "NODE_NAMES and NODE_IPS length differ"
  ADMIN_NAME=${NODE_NAMES[0]}
  ADMIN_IP=${NODE_IPS[0]}
  REGISTRY="${ADMIN_IP}:${REGISTRY_PORT}"
  CEPH_IMAGE_SRC="quay.io/ceph/ceph:v${CEPH_VERSION}"
  CEPH_IMAGE="${REGISTRY}/ceph/ceph:v${CEPH_VERSION}"
  # Tentacle 20.2.4 cephadm DefaultImages (ingress)
  HAPROXY_TAG=${HAPROXY_TAG:-2.3}
  KEEPALIVED_TAG=${KEEPALIVED_TAG:-2.2.4}
  HAPROXY_IMAGE_SRC="quay.io/ceph/haproxy:${HAPROXY_TAG}"
  HAPROXY_IMAGE="${REGISTRY}/ceph/haproxy:${HAPROXY_TAG}"
  KEEPALIVED_IMAGE_SRC="quay.io/ceph/keepalived:${KEEPALIVED_TAG}"
  KEEPALIVED_IMAGE="${REGISTRY}/ceph/keepalived:${KEEPALIVED_TAG}"
  # VIP / ingress placeholders (optional until setup-ingress-vip.sh)
  VIP_ADDR=${VIP_ADDR:-}
  VIP_CIDR=${VIP_CIDR:-24}
  VIP_INTERFACE_NETWORK=${VIP_INTERFACE_NETWORK:-${PUBLIC_NETWORK:-}}
  VRRP_INTERFACE_NETWORK=${VRRP_INTERFACE_NETWORK:-}
  INGRESS_BACKEND_SERVICE=${INGRESS_BACKEND_SERVICE:-mon}
  INGRESS_FRONTEND_PORT=${INGRESS_FRONTEND_PORT:-3300}
  INGRESS_MONITOR_PORT=${INGRESS_MONITOR_PORT:-1967}
  INGRESS_KEEPALIVE_ONLY=${INGRESS_KEEPALIVE_ONLY:-1}
  INGRESS_SERVICE_ID=${INGRESS_SERVICE_ID:-mon}
}

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }

# index of this host in NODE_NAMES, or -1
self_index() {
  local me i; me=$(hostname -s)
  for i in "${!NODE_NAMES[@]}"; do
    [ "${NODE_NAMES[$i]}" = "$me" ] && { echo "$i"; return; }
  done
  echo -1
}

ceph_() { cephadm shell -- ceph "$@"; }
