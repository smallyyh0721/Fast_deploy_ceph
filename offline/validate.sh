#!/usr/bin/env bash
# Pre-flight checks for deploy.sh (stage 00). Read-only. Run on node1.
#   ./validate.sh            # config + remote checks over root ssh
#   ./validate.sh --offline  # config checks only (used by deploy.sh --dry-run)
# NTP/chrony is intentionally NOT checked (assumed correct on site).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
OFFLINE=0
for a in "$@"; do case $a in --offline) OFFLINE=1;; *) die "unknown arg $a";; esac; done
load_conf
ERR=0
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; ERR=$((ERR+1)); }
ok()   { printf '  ok   %s\n' "$*"; }
ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
is_ip() { [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done; }
in_net() { # ip cidr
  local net=${2%/*} len=${2#*/} m; is_ip "$1" && is_ip "$net" || return 1
  m=$(( len==0 ? 0 : (0xFFFFFFFF << (32-len)) & 0xFFFFFFFF ))
  [ $(( $(ip2int "$1") & m )) -eq $(( $(ip2int "$net") & m )) ]; }
pow2() { local n=$1; [ "$n" -gt 0 ] && [ $(( n & (n-1) )) -eq 0 ]; }
known() { local n; for n in "${NODE_NAMES[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }

log "config checks ($CONF)"
[ "${#NODE_NAMES[@]}" -ge 1 ] && ok "${#NODE_NAMES[@]} nodes: ${NODE_NAMES[*]}" || bad "NODE_NAMES empty"
[ "$(printf '%s\n' "${NODE_NAMES[@]}" | sort | uniq -d)" = "" ] || bad "duplicate NODE_NAMES"
[ "$(printf '%s\n' "${NODE_IPS[@]}" | sort | uniq -d)" = "" ] || bad "duplicate NODE_IPS"
[[ $PUBLIC_NETWORK =~ ^[0-9.]+/[0-9]+$ ]] || bad "PUBLIC_NETWORK '$PUBLIC_NETWORK' not CIDR"
for i in "${!NODE_IPS[@]}"; do
  in_net "${NODE_IPS[$i]}" "$PUBLIC_NETWORK" && ok "${NODE_NAMES[$i]} ${NODE_IPS[$i]} in $PUBLIC_NETWORK" \
    || bad "${NODE_NAMES[$i]} IP ${NODE_IPS[$i]} invalid or not in PUBLIC_NETWORK $PUBLIC_NETWORK"
done
[ -z "$CLUSTER_NETWORK" ] || [[ $CLUSTER_NETWORK =~ ^[0-9.]+/[0-9]+$ ]] || bad "CLUSTER_NETWORK not CIDR"
[[ $POOL_SIZE =~ ^[1-9]$ && $POOL_MIN_SIZE =~ ^[1-9]$ && $POOL_MIN_SIZE -le $POOL_SIZE ]] || bad "POOL_SIZE/POOL_MIN_SIZE invalid"
case $PG_AUTOSCALE in on|warn|off) ;; *) bad "PG_AUTOSCALE must be on|warn|off";; esac

# OSD devices
NOSD=0; declare -A OSDHOST=() SEEN=()
for e in "${OSD_DEVICES[@]}"; do
  IFS=: read -r h d cls <<<"$e"
  known "$h" || bad "OSD_DEVICES $e: host $h not in NODE_NAMES"
  [[ $d == /dev/disk/by-id/* ]] || bad "OSD_DEVICES $e: only /dev/disk/by-id/* allowed"
  [[ $d == *-part[0-9]* ]] && bad "OSD_DEVICES $e: partition path not allowed"
  [ -z "${SEEN[$h:$d]:-}" ] || bad "OSD_DEVICES $e listed twice"
  SEEN[$h:$d]=1; OSDHOST[$h]=1; NOSD=$((NOSD+1)); : "${cls:-}"
done
[ "$NOSD" -gt 0 ] && ok "$NOSD OSD devices on ${#OSDHOST[@]} hosts (collocated, no separate WAL/DB)" || bad "OSD_DEVICES empty"
[ "${#OSDHOST[@]}" -ge "$POOL_SIZE" ] && ok "OSD hosts ${#OSDHOST[@]} >= POOL_SIZE $POOL_SIZE" \
  || bad "only ${#OSDHOST[@]} OSD hosts < POOL_SIZE $POOL_SIZE (failure domain=host)"

# pools / PG budget
PGREP=0
for e in "${RBD_POOLS[@]}"; do
  IFS=: read -r n pg sz ratio <<<"$e"; sz=${sz:-$POOL_SIZE}
  [[ $n =~ ^[A-Za-z0-9._-]+$ ]] || bad "RBD_POOLS '$e': bad name"
  [[ $pg =~ ^[0-9]+$ ]] && pow2 "$pg" || bad "RBD_POOLS '$e': pg_num must be power of 2"
  [[ $sz =~ ^[1-9]$ ]] && [ "$sz" -le "${#OSDHOST[@]}" ] || bad "RBD_POOLS '$e': size $sz > OSD hosts"
  [ -z "${ratio:-}" ] || [[ $ratio =~ ^0?\.[0-9]+$|^1(\.0+)?$ ]] || bad "RBD_POOLS '$e': ratio must be 0..1"
  [[ $pg =~ ^[0-9]+$ ]] && PGREP=$((PGREP + pg*sz))
done
if [ "$ENABLE_CEPHFS" = 1 ]; then
  for pg in "$META_PG" "$DATA_PG"; do pow2 "$pg" || bad "CephFS pg $pg not power of 2"; PGREP=$((PGREP+pg*POOL_SIZE)); done
  for h in "${MDS_HOSTS[@]}"; do known "$h" || bad "MDS_HOSTS $h not in NODE_NAMES"; done
fi
if [ "$ENABLE_RGW" = 1 ]; then
  pow2 "$RGW_DATA_PG" || bad "RGW_DATA_PG not power of 2"; PGREP=$((PGREP + (RGW_DATA_PG + 6*8)*POOL_SIZE))
  [ "${#RGW_HOSTS[@]}" -gt 0 ] || bad "ENABLE_RGW=1 but RGW_HOSTS empty"
  for h in "${RGW_HOSTS[@]}"; do known "$h" || bad "RGW_HOSTS $h not in NODE_NAMES"; done
  if [ "$RGW_INGRESS" = 1 ]; then
    is_ip "$RGW_VIP" || bad "RGW_INGRESS=1: RGW_VIP '$RGW_VIP' not a bare IP"
    in_net "$RGW_VIP" "$RGW_VIP_INTERFACE_NETWORK" || bad "RGW_VIP $RGW_VIP not in $RGW_VIP_INTERFACE_NETWORK"
    for ip in "${NODE_IPS[@]}"; do [ "$ip" != "$RGW_VIP" ] || bad "RGW_VIP equals a node IP"; done
    [ "$RGW_VIP" != "$VIP_ADDR" ] || bad "RGW_VIP must differ from mon VIP_ADDR"
    [ "$RGW_FRONTEND_PORT" != "$RGW_PORT" ] || bad "RGW_FRONTEND_PORT must differ from RGW_PORT (same hosts)"
    [ "$RGW_MONITOR_PORT" != "$INGRESS_MONITOR_PORT" ] || bad "RGW_MONITOR_PORT clashes with mon ingress"
    ok "RGW VIP ${RGW_VIP}/${RGW_VIP_CIDR} :$RGW_FRONTEND_PORT -> rgw.$RGW_SERVICE_ID :$RGW_PORT"
  fi
fi
if [ "$ENABLE_MON_VIP" = 1 ]; then
  is_ip "$VIP_ADDR" && in_net "$VIP_ADDR" "$VIP_INTERFACE_NETWORK" || bad "VIP_ADDR '$VIP_ADDR' invalid / not in $VIP_INTERFACE_NETWORK"
fi
if [ "$NOSD" -gt 0 ]; then
  PER=$(( PGREP / NOSD ))
  if [ "$PER" -gt $(( TARGET_PG_PER_OSD * 5 / 2 )) ]; then bad "~$PER PG replicas/OSD (> 2.5x TARGET_PG_PER_OSD=$TARGET_PG_PER_OSD); lower pg_num"
  else ok "~$PER PG replicas/OSD (target $TARGET_PG_PER_OSD)"; fi
fi

if [ "$OFFLINE" = 0 ]; then
  log "remote checks (root ssh BatchMode from $(hostname -s))"
  [ "$(self_index)" -eq 0 ] || bad "run on ${NODE_NAMES[0]} (this is $(hostname -s))"
  for i in "${!NODE_NAMES[@]}"; do
    n=${NODE_NAMES[$i]}; ip=${NODE_IPS[$i]}
    if [ "$i" -eq 0 ]; then r=$(bash -c "hostname -s") || r=""
    else r=$(ssh_node "$ip" "hostname -s" 2>/dev/null) || { bad "$n ($ip): root ssh (BatchMode) failed"; continue; }; fi
    [ "$r" = "$n" ] && ok "$n: ssh ok, hostname -s matches" || bad "$n ($ip): hostname -s is '$r'"
    out=$(on_node "$n" "getent hosts $n | awk '{print \$1}' | head -n1; \
      for d in debs images bin; do [ -d $BUNDLE_DIR/\$d ] || echo MISSING:\$d; done; \
      [ -s $BUNDLE_DIR/bin/cephadm ] || echo MISSING:bin/cephadm; \
      [ -s $BUNDLE_DIR/images/ceph-v${CEPH_VERSION}.tar ] || echo MISSING:images/ceph-v${CEPH_VERSION}.tar; \
      ip -o addr | grep -qw $ip || echo NOIP" 2>/dev/null) || out="SSHFAIL"
    h1=$(head -n1 <<<"$out")
    [ "$h1" = "$ip" ] && ok "$n: /etc/hosts $n -> $ip" || bad "$n: '$n' resolves to '$h1', want $ip (/etc/hosts)"
    grep -q MISSING <<<"$out" && bad "$n: offline bundle incomplete at $BUNDLE_DIR: $(grep MISSING <<<"$out" | tr '\n' ' ')" || ok "$n: bundle present at $BUNDLE_DIR"
    grep -q NOIP <<<"$out" && bad "$n: $ip not configured"
  done
  for e in "${OSD_DEVICES[@]}"; do
    IFS=: read -r h d _ <<<"$e"
    on_node "$h" "test -b '$d'" 2>/dev/null && ok "$h:$d exists" || bad "$h:$d not a block device on $h"
  done
  ALREADY=0; [ -f /etc/ceph/ceph.conf ] && ALREADY=1
  for v in ${RGW_INGRESS:+$([ "$RGW_INGRESS" = 1 ] && echo "$RGW_VIP")} ${ENABLE_MON_VIP:+$([ "$ENABLE_MON_VIP" = 1 ] && echo "$VIP_ADDR")}; do
    if ping -c1 -W1 "$v" >/dev/null 2>&1; then
      [ "$ALREADY" = 1 ] && warn "VIP $v answers (ok if already deployed)" || bad "VIP $v already in use"
    else ok "VIP $v free"; fi
  done
else
  warn "--offline: skipped ssh/hostname/hosts/bundle/disk/VIP checks"
fi
[ "$ERR" -eq 0 ] || die "validate: $ERR problem(s)"
log "validate: OK"
