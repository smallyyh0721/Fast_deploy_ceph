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
  # --- one-click (deploy.sh) fields; all optional, old configs keep working ----
  MANAGE_CHRONY=${MANAGE_CHRONY:-0}; UPSTREAM_NTP=${UPSTREAM_NTP:-}; NTP_ALLOW=${NTP_ALLOW:-${PUBLIC_NETWORK:-}}
  RGW_MONITOR_PORT=${RGW_MONITOR_PORT:-1968}; RGW_VRRP_ROUTER_ID=${RGW_VRRP_ROUTER_ID:-60}; RGW_DATA_PG=${RGW_DATA_PG:-64}
  CLUSTER_NETWORK=${CLUSTER_NETWORK:-}; OSD_MEMORY_TARGET=${OSD_MEMORY_TARGET:-}; LOAD_IMAGE_ON_ALL_NODES=${LOAD_IMAGE_ON_ALL_NODES:-1}
  POOL_SIZE=${POOL_SIZE:-3}; POOL_MIN_SIZE=${POOL_MIN_SIZE:-2}
  PG_AUTOSCALE=${PG_AUTOSCALE:-on}
  TARGET_PG_PER_OSD=${TARGET_PG_PER_OSD:-100}
  declare -p RBD_POOLS >/dev/null 2>&1 || RBD_POOLS=()
  ENABLE_RGW=${ENABLE_RGW:-0}
  RGW_REALM=${RGW_REALM:-default}; RGW_ZONEGROUP=${RGW_ZONEGROUP:-default}; RGW_ZONE=${RGW_ZONE:-default}
  RGW_SERVICE_ID=${RGW_SERVICE_ID:-main}
  declare -p RGW_HOSTS >/dev/null 2>&1 || RGW_HOSTS=()
  RGW_PORT=${RGW_PORT:-8080}
  RGW_INGRESS=${RGW_INGRESS:-0}
  RGW_VIP=${RGW_VIP:-${RGW_VIP_ADDR:-}}; RGW_VIP_CIDR=${RGW_VIP_CIDR:-24}
  RGW_VIP_INTERFACE_NETWORK=${RGW_VIP_INTERFACE_NETWORK:-${PUBLIC_NETWORK:-}}
  RGW_FRONTEND_PORT=${RGW_FRONTEND_PORT:-80}; RGW_MONITOR_PORT=${RGW_MONITOR_PORT:-1968}
  ENABLE_MON_VIP=${ENABLE_MON_VIP:-0}
  ENABLE_CEPHFS=${ENABLE_CEPHFS:-0}
  declare -p MDS_HOSTS >/dev/null 2>&1 || MDS_HOSTS=()
  OSD_UP_TIMEOUT=${OSD_UP_TIMEOUT:-900}
  STATE_DIR=${STATE_DIR:-/var/lib/fast-deploy}
  # --- optional S3 BGP/ECMP entry (setup-s3-bgp.sh / deploy.sh --only s3-bgp) ---
  ENABLE_S3_BGP=${ENABLE_S3_BGP:-0}
  declare -p S3_BGP_HOSTS >/dev/null 2>&1 || S3_BGP_HOSTS=()
  [ "${#S3_BGP_HOSTS[@]}" -gt 0 ] || S3_BGP_HOSTS=("${RGW_HOSTS[@]}")
  S3_BGP_VIP=${S3_BGP_VIP:-$RGW_VIP}
  S3_BGP_LOCAL_ASN=${S3_BGP_LOCAL_ASN:-65050}
  S3_BGP_PEER_IP=${S3_BGP_PEER_IP:-}; S3_BGP_PEER_ASN=${S3_BGP_PEER_ASN:-65000}
  declare -p S3_BGP_ROUTER_IDS >/dev/null 2>&1 || S3_BGP_ROUTER_IDS=()
  S3_BGP_IFACE=${S3_BGP_IFACE:-}; S3_BGP_DUMMY=${S3_BGP_DUMMY:-s3vip0}
  S3_BGP_KEEPALIVE=${S3_BGP_KEEPALIVE:-3}; S3_BGP_HOLD=${S3_BGP_HOLD:-9}
  S3_BGP_PREFIX_LIST=${S3_BGP_PREFIX_LIST:-S3VIP}
  S3_BGP_HAPROXY_CFG=${S3_BGP_HAPROXY_CFG:-}
  S3_BGP_HAPROXY_GLOB=${S3_BGP_HAPROXY_GLOB:-/var/lib/ceph/*/haproxy.rgw.${RGW_SERVICE_ID}.*/haproxy/haproxy.cfg}
  S3_BGP_STATS_URL=${S3_BGP_STATS_URL:-}
  S3_BGP_FRONTEND_NAME=${S3_BGP_FRONTEND_NAME:-frontend}; S3_BGP_BACKEND_NAME=${S3_BGP_BACKEND_NAME:-backend}
  S3_BGP_BACKEND_SERVER_PREFIX=${S3_BGP_BACKEND_SERVER_PREFIX:-rgw.}
  S3_BGP_PROBE_MODE=${S3_BGP_PROBE_MODE:-anon-xml}; S3_BGP_PROBE_URL=${S3_BGP_PROBE_URL:-}
  S3_BGP_PROBE_EXPECT=${S3_BGP_PROBE_EXPECT:-ListAllMyBucketsResult}; S3_BGP_PROBE_CODES=${S3_BGP_PROBE_CODES:-200 403}
  S3_BGP_RISE=${S3_BGP_RISE:-3}; S3_BGP_FALL=${S3_BGP_FALL:-2}; S3_BGP_INTERVAL=${S3_BGP_INTERVAL:-2}
  S3_BGP_WATCHDOG_SEC=${S3_BGP_WATCHDOG_SEC:-15}
  # SSH knobs may be set in cluster.conf; rebuild after sourcing
  SSH_CONNECT_TIMEOUT=${SSH_CONNECT_TIMEOUT:-8}
  SSH_STRICT_HOSTKEY=${SSH_STRICT_HOSTKEY:-0}
  SSH_KNOWN_HOSTS=${SSH_KNOWN_HOSTS:-}
  ssh_build_opts
}

# DRY_RUN=1: mutating commands are printed, not executed.
DRY_RUN=${DRY_RUN:-0}
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}
# root ssh to a cluster node (key auth only, never prompts).
# Default StrictHostKeyChecking=accept-new (first connect pins the key). For pinned-only:
#   SSH_STRICT_HOSTKEY=1
#   SSH_KNOWN_HOSTS=/path/to/known_hosts   # optional UserKnownHostsFile (ssh-keyscan to populate)
# Precedence: assignment in cluster.conf > exported env > default (load_conf rebuilds SSH_OPTS).
# (No top-level defaults here: an unset var stays unset until load_conf, so a conf line
# SSH_STRICT_HOSTKEY=${SSH_STRICT_HOSTKEY-1} can supply a default that env still overrides.)
ssh_build_opts() {
  local strict=${SSH_STRICT_HOSTKEY:-0} kh=${SSH_KNOWN_HOSTS:-} ct=${SSH_CONNECT_TIMEOUT:-8}
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout="$ct")
  case $strict in
    1|yes|YES|true|TRUE) SSH_OPTS+=(-o StrictHostKeyChecking=yes);;
    *) SSH_OPTS+=(-o StrictHostKeyChecking=accept-new);;
  esac
  if [ -n "$kh" ]; then SSH_OPTS+=(-o "UserKnownHostsFile=$kh"); fi
}
ssh_build_opts
# Non-interactive remote: stdin closed (-n). Prefer this for all command invocations.
ssh_node() { local h=$1; shift; ssh -n "${SSH_OPTS[@]}" "root@$h" "$@"; }
# Rare: remote command must read stdin (tar pipe, cat >file). Caller feeds stdin.
ssh_node_in() { local h=$1; shift; ssh "${SSH_OPTS[@]}" "root@$h" "$@"; }
# IP of a node name from NODE_NAMES/NODE_IPS
node_ip() {
  local i; for i in "${!NODE_NAMES[@]}"; do [ "${NODE_NAMES[$i]}" = "$1" ] && { echo "${NODE_IPS[$i]}"; return 0; }; done; return 1
}
# run a command on node (local if it is this host); stdin closed on remote
on_node() {
  local h=$1; shift
  if [ "$h" = "$(hostname -s)" ]; then bash -c "$*"; else ssh_node "$(node_ip "$h" || echo "$h")" "$*"; fi
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

# Always close stdin: cephadm shell would otherwise drain a parent pipeline
# (e.g. `done < "$PLAN_FILE"` in add-osds.sh --apply-plan).
ceph_() { cephadm shell -- ceph "$@" </dev/null; }
