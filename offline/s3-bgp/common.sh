#!/usr/bin/env bash
# Shared by setup-s3-bgp.sh / teardown-s3-bgp.sh (sourced). Pure bash, no python.
# shellcheck disable=SC2034
S3B_LIBDIR=${S3B_LIBDIR:-/usr/local/lib/fast-deploy-s3-bgp}
S3B_ETCDIR=${S3B_ETCDIR:-/etc/fast-deploy-s3-bgp}
S3B_STATE=${S3B_STATE:-/var/lib/fast-deploy-s3-bgp}
S3B_UNITDIR=${S3B_UNITDIR:-/etc/systemd/system}
S3B_FRR_DIR=${S3B_FRR_DIR:-/etc/frr}
S3B_SYSCTL=${S3B_SYSCTL:-/etc/sysctl.d/90-fast-deploy-s3-bgp.conf}
S3B_MARKER="managed-by: fast-deploy-s3-bgp"
S3B_REMOTE_PKG=/var/lib/fast-deploy-s3-bgp/pkg
# every node.conf key (values are written with printf %q)
S3B_NODE_KEYS=(S3_BGP_HOSTNAME S3_BGP_LOCAL_IP S3_BGP_ROUTER_ID S3_BGP_VIP S3_BGP_LOCAL_ASN
  S3_BGP_PEER_IP S3_BGP_PEER_ASN S3_BGP_IFACE S3_BGP_DUMMY S3_BGP_KEEPALIVE S3_BGP_HOLD
  S3_BGP_PREFIX_LIST S3_BGP_HAPROXY_CFG S3_BGP_HAPROXY_GLOB S3_BGP_STATS_URL S3_BGP_FRONTEND_NAME
  S3_BGP_BACKEND_NAME S3_BGP_BACKEND_SERVER_PREFIX S3_BGP_PROBE_MODE S3_BGP_PROBE_URL
  S3_BGP_PROBE_EXPECT S3_BGP_PROBE_CODES S3_BGP_RISE S3_BGP_FALL S3_BGP_INTERVAL
  S3_BGP_WATCHDOG_SEC BUNDLE_DIR)

is_ipv4() {
  local IFS=. o; local -a a
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  read -r -a a <<<"$1"
  for o in "${a[@]}"; do [ "$o" -le 255 ] || return 1; done
}
is_uint() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge "${2:-0}" ]; }
is_asn() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 4294967295 ]; }

# s3b_router_id <host> <default-ip>
# shellcheck disable=SC2153  # S3_BGP_ROUTER_IDS comes from cluster.conf/load_conf
s3b_router_id() {
  local e; for e in "${S3_BGP_ROUTER_IDS[@]}"; do [ "${e%%=*}" = "$1" ] && { echo "${e#*=}"; return 0; }; done
  echo "$2"
}

# s3b_check_conf: validate cluster.conf S3_BGP_* (after load_conf). Prints all problems, returns 1 if any.
s3b_check_conf() {
  local bad=0 h e
  _bad() { printf '  S3_BGP: %s\n' "$*" >&2; bad=1; }
  [ "${RGW_INGRESS:-0}" = 1 ] || _bad "RGW_INGRESS=1 required (BGP entry fronts the existing cephadm ingress HAProxy)"
  is_ipv4 "$S3_BGP_VIP" || _bad "S3_BGP_VIP/RGW_VIP '$S3_BGP_VIP' is not an IPv4 address"
  is_ipv4 "$S3_BGP_PEER_IP" || _bad "S3_BGP_PEER_IP '$S3_BGP_PEER_IP' is not an IPv4 address"
  is_asn "$S3_BGP_LOCAL_ASN" || _bad "S3_BGP_LOCAL_ASN '$S3_BGP_LOCAL_ASN' invalid"
  is_asn "$S3_BGP_PEER_ASN" || _bad "S3_BGP_PEER_ASN '$S3_BGP_PEER_ASN' invalid"
  [ "$S3_BGP_LOCAL_ASN" != "$S3_BGP_PEER_ASN" ] || _bad "local and peer ASN equal (only eBGP is supported)"
  [ "${#S3_BGP_HOSTS[@]}" -gt 0 ] || _bad "S3_BGP_HOSTS (or RGW_HOSTS) is empty"
  for h in "${S3_BGP_HOSTS[@]}"; do
    node_ip "$h" >/dev/null || _bad "host $h not in NODE_NAMES"
    is_ipv4 "$(s3b_router_id "$h" "$(node_ip "$h" || echo x)")" || _bad "router-id for $h invalid"
  done
  for e in "${S3_BGP_ROUTER_IDS[@]}"; do [[ $e == *=* ]] || _bad "S3_BGP_ROUTER_IDS entry '$e' is not host=ip"; done
  [[ $S3_BGP_DUMMY =~ ^[A-Za-z0-9_-]{1,15}$ ]] || _bad "S3_BGP_DUMMY '$S3_BGP_DUMMY' invalid iface name"
  [ -z "$S3_BGP_IFACE" ] || [[ $S3_BGP_IFACE =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || _bad "S3_BGP_IFACE '$S3_BGP_IFACE' invalid"
  [ "$S3_BGP_IFACE" != "$S3_BGP_DUMMY" ] || _bad "S3_BGP_IFACE and S3_BGP_DUMMY are equal"
  [[ $S3_BGP_PREFIX_LIST =~ ^[A-Za-z][A-Za-z0-9_-]{0,40}$ ]] || _bad "S3_BGP_PREFIX_LIST invalid"
  if ! { is_uint "$S3_BGP_KEEPALIVE" 1 && is_uint "$S3_BGP_HOLD" 3 && [ "$S3_BGP_HOLD" -gt "$S3_BGP_KEEPALIVE" ]; }; then
    _bad "timers keepalive=$S3_BGP_KEEPALIVE hold=$S3_BGP_HOLD invalid (hold>keepalive, hold>=3)"
  fi
  case $S3_BGP_PROBE_MODE in anon-xml|http-status|tcp|none) ;; *) _bad "S3_BGP_PROBE_MODE '$S3_BGP_PROBE_MODE' (anon-xml|http-status|tcp|none)";; esac
  if ! { is_uint "$S3_BGP_RISE" 1 && is_uint "$S3_BGP_FALL" 1 && is_uint "$S3_BGP_INTERVAL" 1; }; then
    _bad "RISE/FALL/INTERVAL must be integers >= 1"
  fi
  if is_uint "$S3_BGP_WATCHDOG_SEC" 1 && is_uint "$S3_BGP_INTERVAL" 1; then
    [ "$S3_BGP_WATCHDOG_SEC" -ge $((3 * S3_BGP_INTERVAL + 6)) ] || _bad "S3_BGP_WATCHDOG_SEC must be >= 3*INTERVAL+6"
  else _bad "S3_BGP_WATCHDOG_SEC invalid"; fi
  [ -n "$S3_BGP_HAPROXY_CFG$S3_BGP_HAPROXY_GLOB" ] || _bad "S3_BGP_HAPROXY_CFG and S3_BGP_HAPROXY_GLOB both empty"
  [ "$S3_BGP_VIP" != "${VIP_ADDR:-}" ] || _bad "S3_BGP_VIP equals mon VIP_ADDR"
  return "$bad"
}

# s3b_node_conf <host>: per-node key=value file (stdout). IFACE may stay "" (resolved on node).
s3b_node_conf() {
  local h=$1 ip k
  ip=$(node_ip "$h")
  S3_BGP_HOSTNAME=$h; S3_BGP_LOCAL_IP=$ip
  S3_BGP_ROUTER_ID=$(s3b_router_id "$h" "$ip")
  local stats=${S3_BGP_STATS_URL:-"http://$ip:${RGW_MONITOR_PORT}/stats;csv"}
  local probe=${S3_BGP_PROBE_URL:-"http://$ip:${RGW_PORT}/"}
  echo "# $S3B_MARKER (node $h)"
  for k in "${S3B_NODE_KEYS[@]}"; do
    case $k in
      S3_BGP_STATS_URL) printf '%s=%q\n' "$k" "$stats";;
      S3_BGP_PROBE_URL) printf '%s=%q\n' "$k" "$probe";;
      *) printf '%s=%q\n' "$k" "${!k-}";;
    esac
  done
}

# s3b_render <template> : replace @KEY@ from current S3_BGP_* (node conf sourced)
s3b_render() {
  local ikey=${S3_BGP_IFACE//./\/}
  sed -e "s|@HOSTNAME@|${S3_BGP_HOSTNAME}|g" -e "s|@VIP@|${S3_BGP_VIP}|g" \
      -e "s|@PL@|${S3_BGP_PREFIX_LIST}|g" -e "s|@LOCAL_ASN@|${S3_BGP_LOCAL_ASN}|g" \
      -e "s|@ROUTER_ID@|${S3_BGP_ROUTER_ID}|g" -e "s|@PEER_IP@|${S3_BGP_PEER_IP}|g" \
      -e "s|@PEER_ASN@|${S3_BGP_PEER_ASN}|g" -e "s|@KEEPALIVE@|${S3_BGP_KEEPALIVE}|g" \
      -e "s|@HOLD@|${S3_BGP_HOLD}|g" -e "s|@DUMMY@|${S3_BGP_DUMMY}|g" \
      -e "s|@IFACE@|${S3_BGP_IFACE}|g" -e "s|@IFACE_KEY@|${ikey}|g" \
      -e "s|@WATCHDOG@|${S3_BGP_WATCHDOG_SEC}|g" "$1"
}

# s3b_frr_conf_status <file> [pkg-md5]: absent | ours | pkg-default | foreign
#   pkg-md5 default: md5 of the frr package conffile from dpkg (unmodified package file is safe to replace)
s3b_frr_conf_status() {
  local f=$1 md5=${2-}
  [ -e "$f" ] || { echo absent; return 0; }
  if grep -q "^! $S3B_MARKER" "$f"; then echo ours; return 0; fi
  if [ -z "$md5" ]; then
    md5=$(dpkg-query -W -f='${Conffiles}\n' frr 2>/dev/null | awk -v f="$f" '$1==f {print $2}' || true)
  fi
  if [ -n "$md5" ] && [ "$(md5sum < "$f" | awk '{print $1}')" = "$md5" ]; then echo pkg-default; return 0; fi
  echo foreign
}

# ship this toolkit + node.conf to <ip> and run "<script> --local <node.conf> [args]" there.
# stdin of the remote command is closed; tar is the only thing using the ssh stdin.
# shellcheck disable=SC2029  # remote paths are expanded locally on purpose
s3b_ship_and_run() {
  local ip=$1 nodeconf=$2 script=$3; shift 3
  local src; src=$(cd "$S3B_SRC" && pwd)
  local files=(setup-s3-bgp.sh teardown-s3-bgp.sh s3-bgp)
  [ -f "$src/packages-s3-bgp.list" ] && files+=(packages-s3-bgp.list)
  tar -C "$src" -cf - "${files[@]}" | ssh "${SSH_OPTS[@]}" "root@$ip" \
    "rm -rf '$S3B_REMOTE_PKG' && mkdir -p '$S3B_REMOTE_PKG' && tar -C '$S3B_REMOTE_PKG' -xf -"
  ssh "${SSH_OPTS[@]}" "root@$ip" "cat > '$S3B_REMOTE_PKG/node.conf'" < "$nodeconf"
  ssh "${SSH_OPTS[@]}" "root@$ip" "bash '$S3B_REMOTE_PKG/$script' --local '$S3B_REMOTE_PKG/node.conf' $*" </dev/null
}
