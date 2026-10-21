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
