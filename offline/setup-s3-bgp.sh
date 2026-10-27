#!/usr/bin/env bash
# Optional S3 BGP/ECMP entry on top of the existing cephadm RGW ingress VIP (docs/s3-bgp.md).
# Run as root on node1 from <bundle>/offline (or via ./deploy.sh --only s3-bgp):
#   sudo ./setup-s3-bgp.sh --dry-run        # validate config, print per-node files + actions, change nothing
#   sudo ./setup-s3-bgp.sh                  # configure every S3_BGP_HOSTS node (idempotent)
#   sudo ./setup-s3-bgp.sh --host node2     # only this host (repeatable)
#   ./setup-s3-bgp.sh --check-conf          # config validation only (used by validate.sh)
# Per node: FRR from the offline bundle (only on these nodes), /etc/frr/frr.conf (refuses to
# replace a config not created by this tool), daemons bgpd=yes/bfdd=no, dummy S3_BGP_DUMMY with
# VIP/32, arp_ignore=1/arp_announce=2 on S3_BGP_IFACE only, s3-bgp-network/s3-bgp-health units.
# Never touches management IP, default route, MTU, keepalived/HAProxy, or the switch.
# Internal: setup-s3-bgp.sh --local <node.conf>   (runs on the target node)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S3B_SRC=$HERE
# shellcheck source=s3-bgp/common.sh
. "$HERE/s3-bgp/common.sh"
LOCAL_CONF=""; CHECK_ONLY=0; ONLY_HOSTS=()
DRY_RUN=${DRY_RUN:-0}
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=1;;
    --local) LOCAL_CONF=$2; shift;;
    --check-conf) CHECK_ONLY=1;;
    --host) ONLY_HOSTS+=("$2"); shift;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done

slog() { printf '\033[1;32m[s3-bgp %s]\033[0m %s\n' "$(hostname -s)" "$*"; }
sdie() { printf '\033[1;31m[FAIL]\033[0m s3-bgp %s: %s\n' "$(hostname -s)" "$*" >&2; exit 1; }

# =============================== node-local part =====================================
FRESH=0; INSTALLED=(); CHANGED=0
install_file() {   # src dst mode [owner]
  if [ -f "$2" ] && cmp -s "$1" "$2"; then return 0; fi
  install -D -m "$3" "$1" "$2"
  [ -z "${4:-}" ] || chown "$4" "$2"
  INSTALLED+=("$2"); CHANGED=1
  slog "wrote $2"
}

local_rollback() {
  [ "$FRESH" = 1 ] || { echo "s3-bgp: failure on an existing setup; nothing rolled back, see above" >&2; return 0; }
  echo "s3-bgp: first-time setup failed -> rolling back via teardown-s3-bgp.sh --local" >&2
  bash "$HERE/teardown-s3-bgp.sh" --local "$LOCAL_CONF" || true
}

local_setup() {
  # shellcheck source=/dev/null
  . "$LOCAL_CONF"
  # shellcheck source=s3-bgp/network.sh
  . "$HERE/s3-bgp/network.sh"
  # shellcheck source=s3-bgp/health.sh
  . "$HERE/s3-bgp/health.sh"
  local st cfg tmp f u
  # ---- preflight (read-only; refuses before anything is changed) ----
  if [ -z "$S3_BGP_IFACE" ]; then
    S3_BGP_IFACE=$(ip -o -4 addr show | awk -v ip="$S3_BGP_LOCAL_IP" 'index($4, ip "/")==1 {print $2; exit}')
    [ -n "$S3_BGP_IFACE" ] || sdie "no interface holds $S3_BGP_LOCAL_IP; set S3_BGP_IFACE"
  fi
  ip -o -4 addr show dev "$S3_BGP_IFACE" | awk '{print $4}' | grep -q "^${S3_BGP_LOCAL_IP}/" \
    || sdie "$S3_BGP_IFACE does not hold $S3_BGP_LOCAL_IP"
  [ "$S3_BGP_IFACE" != "$S3_BGP_DUMMY" ] || sdie "iface == dummy"
  st=$(dummy_state "$S3_BGP_DUMMY")
  [[ $st != foreign:* ]] || sdie "refuse: interface $S3_BGP_DUMMY exists and is not ours (${st#foreign:})"
  cfg=$(discover_haproxy_cfg) || sdie "HAProxy cfg not found (${S3_BGP_HAPROXY_CFG:-$S3_BGP_HAPROXY_GLOB}); deploy RGW ingress first"
  slog "haproxy cfg: $cfg"
  st=$(s3b_frr_conf_status "$S3B_FRR_DIR/frr.conf")
  case $st in
    foreign) sdie "refuse: $S3B_FRR_DIR/frr.conf exists, is not the package default and was not created by this tool";;
    *) slog "frr.conf: $st";;
  esac
  if ! dpkg-query -W -f='${Status}' frr 2>/dev/null | grep -q 'install ok installed' && [ -e /usr/sbin/policy-rc.d ]; then
    sdie "refuse: /usr/sbin/policy-rc.d exists and frr must be installed; will not replace it (install frr manually, then rerun)"
  fi
  [ "$(id -u)" -eq 0 ] || sdie "preflight ok; run as root to apply"
  [ -f "$S3B_STATE/managed-files.sha256" ] || FRESH=1
  trap 'rc=$?; [ $rc -eq 0 ] || local_rollback; exit $rc' EXIT

  # ---- FRR from the offline bundle, without starting it unconfigured ----
  mkdir -p "$S3B_STATE/backup"
  if [ ! -f "$S3B_STATE/frr-before.state" ]; then
    { echo "installed=$(dpkg-query -W -f='${Status}' frr 2>/dev/null | grep -q 'install ok installed' && echo 1 || echo 0)"
      echo "enabled=$(systemctl is-enabled frr 2>/dev/null || true)"
      echo "active=$(systemctl is-active frr 2>/dev/null || true)"; } > "$S3B_STATE/frr-before.state"
  fi
  if ! dpkg-query -W -f='${Status}' frr 2>/dev/null | grep -q 'install ok installed'; then
    [ ! -e /usr/sbin/policy-rc.d ] || sdie "/usr/sbin/policy-rc.d exists; refuse to replace it (install frr manually)"
    [ -d "$BUNDLE_DIR/debs" ] || sdie "$BUNDLE_DIR/debs missing"
    ls "$BUNDLE_DIR"/debs/frr_*.deb >/dev/null 2>&1 || sdie "frr .deb not in $BUNDLE_DIR/debs (bundle older than oneclick.2?)"
    local list=/etc/apt/sources.list.d/ceph-offline.list
    echo "deb [trusted=yes] file://$BUNDLE_DIR/debs ./" > "$list"
    apt-get update -q -o Dir::Etc::sourcelist="$list" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 >/dev/null
    cp -n "$BUNDLE_DIR"/debs/*.deb /var/cache/apt/archives/ 2>/dev/null || true
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
    slog "apt install --no-download frr (service start blocked until configured)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-download --no-install-recommends \
         -o Dir::Etc::sourcelist="$list" -o Dir::Etc::sourceparts=- frr </dev/null; then
      rm -f /usr/sbin/policy-rc.d; sdie "frr install failed"
    fi
    rm -f /usr/sbin/policy-rc.d
  fi
  if [ ! -e "$S3B_STATE/backup/.done" ]; then   # first run only: the pre-tool originals
    for f in frr.conf daemons; do
      if [ -f "$S3B_FRR_DIR/$f" ]; then cp -a "$S3B_FRR_DIR/$f" "$S3B_STATE/backup/$f"; fi
    done
    touch "$S3B_STATE/backup/.done"
  fi

  # ---- render + native checks ----
  tmp=$(mktemp -d)
  s3b_render "$HERE/s3-bgp/templates/frr.conf.in" > "$tmp/frr.conf"
  /usr/lib/frr/bgpd -C -f "$tmp/frr.conf" >/dev/null 2>"$tmp/bgpd.err" \
    || { cat "$tmp/bgpd.err" >&2; sdie "bgpd -C rejected rendered frr.conf"; }
  sed -E 's/^bgpd=.*/bgpd=yes/; s/^bfdd=.*/bfdd=no/' "$S3B_FRR_DIR/daemons" > "$tmp/daemons"
  grep -q '^bgpd=yes$' "$tmp/daemons" || sdie "$S3B_FRR_DIR/daemons has no bgpd= line"
  { s3b_node_conf_resolved; } > "$tmp/s3-bgp.conf"
  for u in s3-bgp-network.service s3-bgp-health.service; do s3b_render "$HERE/s3-bgp/templates/$u.in" > "$tmp/$u"; done
  s3b_render "$HERE/s3-bgp/templates/frr-s3-bgp.conf.in" > "$tmp/frr-s3-bgp.conf"
  s3b_render "$HERE/s3-bgp/templates/sysctl-s3-bgp.conf.in" > "$tmp/sysctl.conf"

  # ---- install (only changed files) ----
  install_file "$HERE/s3-bgp/network.sh" "$S3B_LIBDIR/network.sh" 755
  install_file "$HERE/s3-bgp/health.sh" "$S3B_LIBDIR/health.sh" 755
  install_file "$tmp/s3-bgp.conf" "$S3B_ETCDIR/s3-bgp.conf" 600
  systemd-analyze verify "$tmp/s3-bgp-network.service" "$tmp/s3-bgp-health.service" 2>"$tmp/verify.err" \
    || { cat "$tmp/verify.err" >&2; sdie "systemd-analyze verify failed"; }
  local net_changed=$CHANGED; CHANGED=0
  install_file "$tmp/s3-bgp-network.service" "$S3B_UNITDIR/s3-bgp-network.service" 644
  install_file "$tmp/sysctl.conf" "$S3B_SYSCTL" 644
  [ "$CHANGED" = 0 ] || net_changed=1; CHANGED=0
  install_file "$tmp/frr.conf" "$S3B_FRR_DIR/frr.conf" 640 frr:frr
  install_file "$tmp/daemons" "$S3B_FRR_DIR/daemons" 640 frr:frr
  install_file "$tmp/frr-s3-bgp.conf" "$S3B_UNITDIR/frr.service.d/fast-deploy-s3-bgp.conf" 644
  local frr_changed=$CHANGED; CHANGED=0
  install_file "$tmp/s3-bgp-health.service" "$S3B_UNITDIR/s3-bgp-health.service" 644
  local health_changed=$((CHANGED | net_changed | frr_changed))
  rm -rf "$tmp"

  # ---- services ----
  systemctl daemon-reload
  systemctl enable s3-bgp-network.service frr.service s3-bgp-health.service >/dev/null 2>&1
  # boot transaction must stay cycle-free (systemd silently drops a job on a cycle -> nothing starts at reboot)
  local cyc
  cyc=$(systemd-analyze verify default.target 2>&1 | grep -iE 'ordering cycle|to break ordering cycle' | grep -E 's3-bgp|frr' || true)
  [ -z "$cyc" ] || { echo "$cyc" >&2; sdie "boot ordering cycle involving frr/s3-bgp units"; }
  if [ "$net_changed" = 1 ]; then systemctl restart s3-bgp-network.service; else systemctl start s3-bgp-network.service; fi
  if [ "$frr_changed" = 1 ] || ! systemctl is-active -q frr; then systemctl restart frr.service; fi
  if bash "$S3B_LIBDIR/health.sh" check; then :; else slog "health currently NOT ok -> VIP stays withdrawn until healthy"; fi
  if [ "$health_changed" = 1 ]; then systemctl restart s3-bgp-health.service; else systemctl start s3-bgp-health.service; fi
  ( cd / && sha256sum "$S3B_LIBDIR/network.sh" "$S3B_LIBDIR/health.sh" "$S3B_ETCDIR/s3-bgp.conf" \
      "$S3B_UNITDIR/s3-bgp-network.service" "$S3B_UNITDIR/s3-bgp-health.service" "$S3B_SYSCTL" \
      "$S3B_FRR_DIR/frr.conf" "$S3B_FRR_DIR/daemons" "$S3B_UNITDIR/frr.service.d/fast-deploy-s3-bgp.conf" ) \
      > "$S3B_STATE/managed-files.sha256"
  trap - EXIT
  slog "done: ${#INSTALLED[@]} file(s) changed; $(ip -br addr show dev "$S3_BGP_DUMMY" | tr -s ' ')"
  slog "BGP: vtysh -c 'show bgp summary' ; health: cat ${STATE_FILE}"
}

# node.conf as sourced now (IFACE resolved on the node)
s3b_node_conf_resolved() {
  local k
  echo "# $S3B_MARKER (node $S3_BGP_HOSTNAME)"
  for k in "${S3B_NODE_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k-}"; done
}

if [ -n "$LOCAL_CONF" ]; then local_setup; exit 0; fi

# =============================== orchestrator (node1) =================================
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_conf
[ "$CHECK_ONLY" = 1 ] || [ "$ENABLE_S3_BGP" = 1 ] || die "ENABLE_S3_BGP=0 in $CONF; set it to 1 to use the BGP entry (optional feature)"
if ! s3b_check_conf; then die "S3 BGP config invalid (see above)"; fi
[ "$CHECK_ONLY" = 0 ] || { log "S3 BGP config OK (hosts: ${S3_BGP_HOSTS[*]})"; exit 0; }
[ "$DRY_RUN" = 1 ] || need_root
HOSTS=("${S3_BGP_HOSTS[@]}")
if [ "${#ONLY_HOSTS[@]}" -gt 0 ]; then
  for h in "${ONLY_HOSTS[@]}"; do [[ " ${S3_BGP_HOSTS[*]} " == *" $h "* ]] || die "--host $h not in S3_BGP_HOSTS"; done
  HOSTS=("${ONLY_HOSTS[@]}")
fi
log "S3 BGP: VIP ${S3_BGP_VIP}/32  AS${S3_BGP_LOCAL_ASN} -> peer ${S3_BGP_PEER_IP} AS${S3_BGP_PEER_ASN}  hosts: ${HOSTS[*]}  dry-run=$DRY_RUN"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
for h in "${HOSTS[@]}"; do
  ip=$(node_ip "$h")
  s3b_node_conf "$h" > "$WORK/$h.conf"
  if [ "$DRY_RUN" = 1 ]; then
    (
      # shellcheck source=/dev/null
      . "$WORK/$h.conf"
      [ -n "$S3_BGP_IFACE" ] || S3_BGP_IFACE="<iface-holding-node-ip>"
      echo "---- $h ($ip) ----"
      echo "  [dry-run] ship setup-s3-bgp.sh + s3-bgp/ to root@$ip:$S3B_REMOTE_PKG, run --local (as root, stdin closed)"
      echo "  [dry-run] preflight: iface holds $S3_BGP_LOCAL_IP; dummy $S3_BGP_DUMMY absent or ours; haproxy.cfg found (${S3_BGP_HAPROXY_CFG:-$S3_BGP_HAPROXY_GLOB}); $S3B_FRR_DIR/frr.conf absent/package-default/ours else REFUSE"
      echo "  [dry-run] apt install --no-download frr from $BUNDLE_DIR/debs if missing (policy-rc.d blocks autostart); backup $S3B_FRR_DIR/{frr.conf,daemons} -> $S3B_STATE/backup"
      echo "  [dry-run] $S3B_FRR_DIR/daemons: bgpd=yes bfdd=no (other lines untouched); bgpd -C + systemd-analyze verify before install"
      echo "  [dry-run] write $S3B_FRR_DIR/frr.conf:"; s3b_render "$HERE/s3-bgp/templates/frr.conf.in" | sed 's/^/      /'
      echo "  [dry-run] write $S3B_SYSCTL:"; s3b_render "$HERE/s3-bgp/templates/sysctl-s3-bgp.conf.in" | grep -v '^#' | sed 's/^/      /'
      echo "  [dry-run] units: s3-bgp-network.service (dummy $S3_BGP_DUMMY ${S3_BGP_VIP}/32), frr.service.d drop-in, s3-bgp-health.service (WatchdogSec=${S3_BGP_WATCHDOG_SEC})"
      echo "  [dry-run] health: stats $S3_BGP_STATS_URL ($S3_BGP_FRONTEND_NAME OPEN + $S3_BGP_BACKEND_NAME/${S3_BGP_BACKEND_SERVER_PREFIX}* UP), probe $S3_BGP_PROBE_MODE $S3_BGP_PROBE_URL; rise $S3_BGP_RISE / fall $S3_BGP_FALL / every ${S3_BGP_INTERVAL}s"
      echo "  [dry-run] advertise/withdraw: vtysh router bgp $S3_BGP_LOCAL_ASN / address-family ipv4 unicast / [no] network ${S3_BGP_VIP}/32"
    )
    continue
  fi
  log "== $h ($ip)"
  if [ "$h" = "$(hostname -s)" ]; then
    bash "$HERE/setup-s3-bgp.sh" --local "$WORK/$h.conf" </dev/null
  else
    s3b_ship_and_run "$ip" "$WORK/$h.conf" setup-s3-bgp.sh
  fi
done
[ "$DRY_RUN" = 1 ] || log "S3 BGP configured on: ${HOSTS[*]}. Switch side (manual): docs/s3-bgp-switch-h3c.md; check: ./verify.sh"
