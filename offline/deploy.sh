#!/usr/bin/env bash
# One-click deployment, run as root on node1 (NODE_NAMES[0]) from <bundle>/offline.
#   sudo ./deploy.sh                       # all stages, resumes after the last finished one
#   sudo ./deploy.sh --dry-run             # print what each stage would do (no changes, no root)
#   sudo ./deploy.sh --from osd-preview    # (re)start at a stage
#   sudo ./deploy.sh --only pools          # run exactly one stage
#   sudo ./deploy.sh --reset-stage rgw     # forget the done-marker of a stage (then exit)
#   --yes   skip the "start deployment?" prompt. It does NOT skip the OSD typed confirmation.
#   --list  show stages and their markers
# Stages: validate install bootstrap hosts osd-preview osd pools rgw cephfs vip monitoring verify
#   monitoring = setup-monitoring.sh (ENABLE_MONITORING/ENABLE_DASHBOARD, default on); an existing
#   cluster gets it with --only monitoring
# Optional (never in the default run / --from): --only s3-bgp  (ENABLE_S3_BGP=1, docs/s3-bgp.md)
# Markers: $STATE_DIR/<stage>.done (contain sha256 of cluster.conf).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"
STAGES=(validate install bootstrap hosts osd-preview osd pools rgw cephfs vip monitoring verify)
OPT_STAGES=(s3-bgp)   # only via --only / --reset-stage
FROM=""; ONLY=""; RESET=""; YES=0; LIST=0
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=1;;
    --from) FROM=$2; shift;;
    --only) ONLY=$2; shift;;
    --reset-stage) RESET=$2; shift;;
    --yes|-y) YES=1;;
    --list) LIST=1;;
    -h|--help) sed -n '2,16p' "$0"; exit 0;;
    *) die "unknown arg $1";;
  esac; shift
done
export DRY_RUN
DRYFLAG=(); [ "$DRY_RUN" = 1 ] && DRYFLAG=(--dry-run)
valid_stage() { local s; for s in "${STAGES[@]}"; do [ "$s" = "$1" ] && return 0; done; die "unknown stage '$1' (${STAGES[*]})"; }
is_opt_stage() { local s; for s in "${OPT_STAGES[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
for s in $FROM; do valid_stage "$s"; done
for s in $ONLY $RESET; do is_opt_stage "$s" || valid_stage "$s"; done
[ -z "$FROM" ] || [ -z "$ONLY" ] || die "--from and --only are exclusive"
[ "$DRY_RUN" = 1 ] || [ "$LIST" = 1 ] || need_root
load_conf
[ "$DRY_RUN" = 1 ] || [ "$(self_index)" -eq 0 ] || die "run deploy.sh on ${NODE_NAMES[0]} (this is $(hostname -s))"
CONF_SHA=$(sha256sum "$CONF" | awk '{print $1}')
marker() { echo "$STATE_DIR/$1.done"; }
is_done() { [ -f "$(marker "$1")" ]; }
mark_done() { [ "$DRY_RUN" = 1 ] && return 0; mkdir -p "$STATE_DIR"; printf 'conf_sha256=%s\ndone=%s\n' "$CONF_SHA" "$(date -Is)" > "$(marker "$1")"; }

if [ -n "$RESET" ]; then rm -f "$(marker "$RESET")"; [ "$RESET" = osd-preview ] && rm -f "$STATE_DIR/osd-plan.txt"; log "reset $RESET"; exit 0; fi
if [ "$LIST" = 1 ]; then
  for s in "${STAGES[@]}"; do
    if is_done "$s"; then printf '  %-12s done %s\n' "$s" "$(grep -h ^done= "$(marker "$s")" | cut -d= -f2)"; else printf '  %-12s -\n' "$s"; fi
  done
  for s in "${OPT_STAGES[@]}"; do
    if is_done "$s"; then printf '  %-12s done %s (optional, --only)\n' "$s" "$(grep -h ^done= "$(marker "$s")" | cut -d= -f2)"; else printf '  %-12s - (optional, --only)\n' "$s"; fi
  done; exit 0
fi

# ---- stages -------------------------------------------------------------------------
REMOTE_DIR="$BUNDLE_DIR/offline"
stage_validate() { if [ "$DRY_RUN" = 1 ]; then "$HERE/validate.sh" --offline; else "$HERE/validate.sh"; fi; }
stage_install() {
  local i n ip
  for i in "${!NODE_NAMES[@]}"; do   # node1 first (registry), then the others
    n=${NODE_NAMES[$i]}; ip=${NODE_IPS[$i]}
    log "install-node.sh on $n ($ip)"
    if [ "$i" -eq 0 ]; then
      run bash "$HERE/install-node.sh" --verify-payload
    else
      # ship this toolkit + cluster.conf so every node runs the same script version
      run ssh_node "$ip" "mkdir -p '$REMOTE_DIR'"
      local files=() f
      for f in "$HERE"/*.sh; do [[ $f == *s3-bgp* ]] || files+=("$f"); done   # s3-bgp ships itself
      files+=("$CONF")
      for f in packages.list images.list; do [ -f "$HERE/$f" ] && files+=("$HERE/$f"); done
      run scp -q "${SSH_OPTS[@]}" "${files[@]}" "root@$ip:$REMOTE_DIR/"
      [ "$(basename "$CONF")" = cluster.conf ] || run ssh_node "$ip" "cp '$REMOTE_DIR/$(basename "$CONF")' '$REMOTE_DIR/cluster.conf'"
      run ssh_node "$ip" "cd '$REMOTE_DIR' && bash ./install-node.sh --verify-payload"
    fi
  done
}
stage_bootstrap() { run bash "$HERE/bootstrap.sh"; }
stage_hosts() { run bash "$HERE/add-hosts.sh" --apply; }
stage_osd_preview() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] ssh -n each OSD host: scp disk-safety.sh -> $BUNDLE_DIR/offline/disk-safety.sh.tmp.<node1 pid>, chmod+mv to final path (any failure: rm .tmp, abort); bash <path> probe (lsblk/pvs/lvs/findmnt/wipefs) -> table CREATE/NEEDS-ZAP/SKIP/REFUSE"
    echo "  [dry-run] any REFUSE -> abort; then operator types YES-WIPE-<N> + serial last-4 per NEEDS-ZAP disk (cannot be skipped, also not by --yes)"
    local e; for e in "${OSD_DEVICES[@]}"; do echo "    candidate ${e%%:*} $(cut -d: -f2 <<<"$e")"; done
    echo "  [dry-run] write $STATE_DIR/osd-plan.txt"
    return 0
  fi
  bash "$HERE/add-osds.sh" --confirm --plan "$STATE_DIR/osd-plan.txt"
}
stage_osd() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] add-osds.sh --apply-plan $STATE_DIR/osd-plan.txt: re-probe, refuse if anything changed,"
    echo "            'ceph orch device zap <host> <by-id> --force' only for confirmed NEEDS-ZAP, 'ceph orch daemon add osd <host>:<by-id>'"
    echo "  [dry-run] wait until num_up_osds >= before + planned (timeout ${OSD_UP_TIMEOUT}s)"
    return 0
  fi
  [ -s "$STATE_DIR/osd-plan.txt" ] || die "no confirmed OSD plan; run --from osd-preview"
  bash "$HERE/add-osds.sh" --apply-plan "$STATE_DIR/osd-plan.txt"
}
stage_pools() { bash "$HERE/setup-pools.sh" "${DRYFLAG[@]}"; }
stage_rgw() { [ "$ENABLE_RGW" = 1 ] || { log "ENABLE_RGW=0, skip"; return 0; }; bash "$HERE/setup-rgw.sh" "${DRYFLAG[@]}"; }
stage_cephfs() { [ "$ENABLE_CEPHFS" = 1 ] || { log "ENABLE_CEPHFS=0, skip"; return 0; }; run bash "$HERE/setup-cephfs.sh"; }
stage_vip() { [ "$ENABLE_MON_VIP" = 1 ] || { log "ENABLE_MON_VIP=0, skip"; return 0; }; run bash "$HERE/setup-ingress-vip.sh" --apply; }
stage_monitoring() {
  if [ "$ENABLE_MONITORING" != 1 ] && [ "$ENABLE_DASHBOARD" != 1 ]; then log "ENABLE_MONITORING=0 ENABLE_DASHBOARD=0, skip"; return 0; fi
  bash "$HERE/setup-monitoring.sh" "${DRYFLAG[@]}"
}
stage_verify() { bash "$HERE/verify.sh" "${DRYFLAG[@]}"; }
stage_s3_bgp() {
  [ "$ENABLE_S3_BGP" = 1 ] || die "ENABLE_S3_BGP=0 in $CONF (optional BGP entry, docs/s3-bgp.md)"
  bash "$HERE/setup-s3-bgp.sh" "${DRYFLAG[@]}"
}

# ---- select & run -------------------------------------------------------------------
SEL=(); started=0
for s in "${STAGES[@]}" "${OPT_STAGES[@]}"; do
  if is_opt_stage "$s"; then [ "$s" = "$ONLY" ] && SEL+=("$s"); continue; fi
  if [ -n "$ONLY" ]; then [ "$s" = "$ONLY" ] && SEL+=("$s"); continue; fi
  if [ -n "$FROM" ]; then [ "$s" = "$FROM" ] && started=1; [ "$started" = 1 ] && SEL+=("$s"); continue; fi
  SEL+=("$s")
done
log "config $CONF (sha256 ${CONF_SHA:0:12}) nodes: ${NODE_NAMES[*]}  dry-run=$DRY_RUN"
log "stages: ${SEL[*]}"
if [ "$DRY_RUN" != 1 ] && [ "$YES" != 1 ]; then
  read -r -p "Start deployment? [y/N] " a; [[ $a == [yY]* ]] || die "aborted"
fi
for s in "${SEL[@]}"; do
  explicit=0; { [ -n "$ONLY" ] || [ "$s" = "$FROM" ]; } && explicit=1
  if is_done "$s" && [ "$explicit" = 0 ] && [ "$s" != validate ] && [ "$s" != verify ]; then
    grep -q "conf_sha256=$CONF_SHA" "$(marker "$s")" || warn "$s was done with a different cluster.conf; use --from $s to redo"
    log "== $s: already done, skip"; continue
  fi
  log "== stage $s"
  CUR_STAGE=$s
  trap '[ $? -eq 0 ] || printf "\033[1;31m[FAIL]\033[0m stage %s failed; fix and resume with: ./deploy.sh --from %s\n" "$CUR_STAGE" "$CUR_STAGE" >&2' EXIT
  "stage_${s//-/_}"
  mark_done "$s"
done
log "deploy.sh finished (${SEL[*]})"
