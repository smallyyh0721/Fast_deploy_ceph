#!/usr/bin/env bash
# Remove the optional S3 BGP entry (setup-s3-bgp.sh). Run as root on node1:
#   sudo ./teardown-s3-bgp.sh --dry-run      # print what would be done
#   sudo ./teardown-s3-bgp.sh [--host node2] # withdraw VIP/32, stop health/network units,
#        delete our dummy, restore ARP sysctls, restore /etc/frr/{frr.conf,daemons} from the
#        backup taken before setup, restore frr.service enabled/active state, remove our files.
# The frr package stays installed (offline re-install is not needed for a later setup).
# The cephadm ingress VIP (keepalived/HAProxy) is not touched. Switch config: manual,
# docs/s3-bgp-switch-h3c.md (rollback section) - do the switch side FIRST.
# Internal: teardown-s3-bgp.sh --local [node.conf]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S3B_SRC=$HERE
# shellcheck source=s3-bgp/common.sh
. "$HERE/s3-bgp/common.sh"
LOCAL=0; LOCAL_CONF=""; ONLY_HOSTS=()
DRY_RUN=${DRY_RUN:-0}
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=1;;
    --local) LOCAL=1; if [ $# -gt 1 ] && [[ $2 != --* ]]; then LOCAL_CONF=$2; shift; fi;;
    --host) ONLY_HOSTS+=("$2"); shift;;
    -h|--help) sed -n '2,11p' "$0"; exit 0;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done
tlog() { printf '\033[1;32m[s3-bgp-teardown %s]\033[0m %s\n' "$(hostname -s)" "$*"; }

local_teardown() {
  [ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
  local conf=$S3B_ETCDIR/s3-bgp.conf
  [ -f "$conf" ] || conf=$LOCAL_CONF
  if [ -z "$conf" ] || [ ! -f "$conf" ]; then tlog "no s3-bgp config on this node; nothing to do"; return 0; fi
  # shellcheck source=/dev/null
  . "$conf"
  export S3_BGP_NODE_CONF=$conf S3_BGP_STATE_DIR=$S3B_STATE
  # shellcheck source=s3-bgp/network.sh
  . "$HERE/s3-bgp/network.sh"
  # 1. withdraw first (ExecStopPost also withdraws; explicit call covers a missing unit)
  systemctl disable --now s3-bgp-health.service >/dev/null 2>&1 || true
  if systemctl is-active -q frr 2>/dev/null; then
    S3_BGP_NODE_CONF=$conf bash "$HERE/s3-bgp/health.sh" withdraw || tlog "withdraw via vtysh failed (frr down?)"
  fi
  # 2. dummy + ARP (unit stop runs network.sh down; then once more directly, idempotent)
  systemctl disable --now s3-bgp-network.service >/dev/null 2>&1 || true
  net_down
  # 3. FRR config: only if the current file is still ours
  local frrst
  frrst=$(s3b_frr_conf_status "$S3B_FRR_DIR/frr.conf")
  if [ "$frrst" = ours ]; then
    if [ -f "$S3B_STATE/backup/frr.conf" ]; then cp -a "$S3B_STATE/backup/frr.conf" "$S3B_FRR_DIR/frr.conf"; tlog "restored frr.conf"
    else rm -f "$S3B_FRR_DIR/frr.conf"; tlog "removed frr.conf (none before)"; fi
    if [ -f "$S3B_STATE/backup/daemons" ]; then cp -a "$S3B_STATE/backup/daemons" "$S3B_FRR_DIR/daemons"; tlog "restored daemons"; fi
  else
    tlog "frr.conf is $frrst (not ours) -> frr.conf/daemons left as is"
  fi
  # 4. our files
  rm -f "$S3B_UNITDIR/s3-bgp-health.service" "$S3B_UNITDIR/s3-bgp-network.service" \
        "$S3B_UNITDIR/frr.service.d/fast-deploy-s3-bgp.conf" "$S3B_SYSCTL"
  rmdir "$S3B_UNITDIR/frr.service.d" 2>/dev/null || true
  rm -rf "$S3B_LIBDIR" "$S3B_ETCDIR"
  rm -f /run/fast-deploy-s3-bgp-health.state
  systemctl daemon-reload
  # 5. frr service back to its pre-setup state (only if setup recorded it; otherwise
  #    setup never touched frr.service, so leave it alone)
  local before_enabled="" before_active=""
  if [ -f "$S3B_STATE/frr-before.state" ]; then
    before_enabled=$(sed -n 's/^enabled=//p' "$S3B_STATE/frr-before.state")
    before_active=$(sed -n 's/^active=//p' "$S3B_STATE/frr-before.state")
  fi
  if [ -f "$S3B_STATE/frr-before.state" ] && systemctl cat frr.service >/dev/null 2>&1; then
    if [ "$before_active" = active ]; then systemctl restart frr.service; else systemctl stop frr.service || true; fi
    if [ "$before_enabled" = enabled ]; then systemctl enable frr.service >/dev/null 2>&1 || true
    else systemctl disable frr.service >/dev/null 2>&1 || true; fi
    tlog "frr.service -> enabled=${before_enabled:-disabled} active=${before_active:-inactive} (package kept installed)"
  fi
  rm -rf "$S3B_STATE"
  tlog "done: ${S3_BGP_VIP}/32 withdrawn, $S3_BGP_DUMMY removed (if ours), ARP restored from saved values (if any)"
}

if [ "$LOCAL" = 1 ]; then local_teardown; exit 0; fi

# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_conf
[ "$DRY_RUN" = 1 ] || need_root
HOSTS=("${S3_BGP_HOSTS[@]}")
[ "${#ONLY_HOSTS[@]}" -eq 0 ] || HOSTS=("${ONLY_HOSTS[@]}")
[ "${#HOSTS[@]}" -gt 0 ] || die "no S3_BGP_HOSTS/RGW_HOSTS"
log "S3 BGP teardown on: ${HOSTS[*]}  dry-run=$DRY_RUN  (switch side first: docs/s3-bgp-switch-h3c.md rollback)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
for h in "${HOSTS[@]}"; do
  ip=$(node_ip "$h") || die "host $h not in NODE_NAMES"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] $h ($ip): stop+disable s3-bgp-health (vtysh no network ${S3_BGP_VIP}/32), stop+disable s3-bgp-network"
    echo "  [dry-run] $h: delete dummy $S3_BGP_DUMMY if alias=fast-deploy-s3-bgp; restore arp_ignore/arp_announce from $S3B_STATE/arp-before.conf"
    echo "  [dry-run] $h: restore $S3B_FRR_DIR/{frr.conf,daemons} from $S3B_STATE/backup (frr.conf only if still ours); remove units/drop-in/$S3B_SYSCTL/$S3B_LIBDIR/$S3B_ETCDIR"
    echo "  [dry-run] $h: frr.service back to pre-setup enabled/active state; frr package kept"
    continue
  fi
  log "== $h ($ip)"
  s3b_node_conf "$h" > "$WORK/$h.conf"
  if [ "$h" = "$(hostname -s)" ]; then
    bash "$HERE/teardown-s3-bgp.sh" --local "$WORK/$h.conf" </dev/null
  else
    s3b_ship_and_run "$ip" "$WORK/$h.conf" teardown-s3-bgp.sh
  fi
done
