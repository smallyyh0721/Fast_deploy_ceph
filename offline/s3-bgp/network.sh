#!/usr/bin/env bash
# fast-deploy-s3-bgp: dummy interface holding VIP/32 + ARP sysctls on the business iface ONLY.
#   network.sh up | down | status
# Never touches management IP, default route, MTU, physical/bridge/VLAN config or the
# keepalived-held VIP/prefix on the business interface.
set -euo pipefail
NODE_CONF=${S3_BGP_NODE_CONF:-/etc/fast-deploy-s3-bgp/s3-bgp.conf}
STATE_DIR=${S3_BGP_STATE_DIR:-/var/lib/fast-deploy-s3-bgp}
IP_CMD=${IP_CMD:-ip}
SYSCTL_CMD=${SYSCTL_CMD:-sysctl}
OWNER_ALIAS="fast-deploy-s3-bgp"

nlog() { echo "s3-bgp-network: $*" >&2; }
iface_key() { echo "${1//./\/}"; }   # sysctl key form (VLAN dots -> slashes)

# dummy_state <dev>: absent | ours | foreign:<reason>  (reads `ip -d -o link/addr`)
dummy_state() {
  local dev=$1 link addrs
  link=$($IP_CMD -d -o link show dev "$dev" 2>/dev/null) || { echo absent; return 0; }
  [[ $link == *" dummy "* ]] || { echo "foreign:not a dummy interface"; return 0; }
  [[ $link == *"alias $OWNER_ALIAS"* ]] || { echo "foreign:alias is not $OWNER_ALIAS"; return 0; }
  addrs=$($IP_CMD -o -4 addr show dev "$dev" 2>/dev/null | awk '{print $4}' | grep -v "^${S3_BGP_VIP}/32$" || true)
  [ -z "$addrs" ] || { echo "foreign:unexpected address(es) $addrs"; return 0; }
  echo ours
}

net_up() {
  local st key f
  st=$(dummy_state "$S3_BGP_DUMMY")
  [[ $st != foreign:* ]] || { nlog "refuse: $S3_BGP_DUMMY exists and is not ours (${st#foreign:})"; return 1; }
  key=$(iface_key "$S3_BGP_IFACE")
  mkdir -p "$STATE_DIR"
  f="$STATE_DIR/arp-before.conf"
  if [ ! -s "$f" ]; then   # first time only: keeps the true original across reboots
    { echo "net.ipv4.conf.$key.arp_ignore=$($SYSCTL_CMD -n "net.ipv4.conf.$key.arp_ignore")"
      echo "net.ipv4.conf.$key.arp_announce=$($SYSCTL_CMD -n "net.ipv4.conf.$key.arp_announce")"; } > "$f.tmp"
    mv "$f.tmp" "$f"
  fi
  $SYSCTL_CMD -q -w "net.ipv4.conf.$key.arp_ignore=1" "net.ipv4.conf.$key.arp_announce=2"
  if [ "$st" = absent ]; then
    $IP_CMD link add "$S3_BGP_DUMMY" type dummy
    $IP_CMD link set dev "$S3_BGP_DUMMY" alias "$OWNER_ALIAS"
  fi
  $IP_CMD link set dev "$S3_BGP_DUMMY" up
  $IP_CMD address replace "${S3_BGP_VIP}/32" dev "$S3_BGP_DUMMY"
  nlog "up: $S3_BGP_DUMMY ${S3_BGP_VIP}/32, $S3_BGP_IFACE arp_ignore=1 arp_announce=2"
}

net_down() {
  local st f
  st=$(dummy_state "$S3_BGP_DUMMY")
  case $st in
    ours) $IP_CMD link delete dev "$S3_BGP_DUMMY" type dummy; nlog "deleted $S3_BGP_DUMMY";;
    absent) ;;
    *) nlog "leave $S3_BGP_DUMMY alone (${st#foreign:})";;
  esac
  f="$STATE_DIR/arp-before.conf"
  if [ -s "$f" ]; then
    # shellcheck disable=SC2046
    $SYSCTL_CMD -q -w $(grep -E '^net\.ipv4\.conf\.[^ ]+\.arp_(ignore|announce)=[0-9]+$' "$f")
    nlog "restored ARP sysctls from $f"
  fi
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  # shellcheck source=/dev/null
  . "$NODE_CONF"
  case ${1:-} in
    up) net_up;;
    down) net_down;;
    status) echo "dummy=$(dummy_state "$S3_BGP_DUMMY")"; $IP_CMD -br addr show dev "$S3_BGP_DUMMY" 2>/dev/null || true;;
    *) echo "usage: $0 up|down|status" >&2; exit 2;;
  esac
fi
