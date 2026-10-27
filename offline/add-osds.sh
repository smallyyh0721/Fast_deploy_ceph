#!/usr/bin/env bash
# Run on node1. Creates one OSD per device in OSD_DEVICES ("host:/dev/disk/by-id/..[:class]"),
# data+WAL+DB collocated on the same disk. NEVER uses --all-available-devices.
#
#   ./add-osds.sh                          # PREVIEW only (safety table, no changes)
#   ./add-osds.sh --confirm [--plan F]     # preview + typed confirmation -> writes plan file
#   ./add-osds.sh --apply-plan F           # re-check every disk, zap confirmed disks, create OSDs
#   ./add-osds.sh --yes-i-really-mean-it   # legacy: preview + typed confirmation + apply
#   options: --host NODE  --skip-refused  --dry-run
#
# Typed confirmation is mandatory for any wipe/create: "YES-WIPE-<N>" then, for every disk
# that has old data (NEEDS-ZAP), the last 4 characters of its serial. No flag skips it
# (deploy.sh --yes does not either). REFUSE rows (root/boot/EFI/swap disk, mounted, md,
# non-Ceph LVM, non-by-id path, ...) are never wiped; any REFUSE aborts unless --skip-refused.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

print_plan() {
  printf '\n%-9s %-8s %-48s %-8s %8s %-22s %-16s %-4s %s\n' ACTION HOST BY-ID KNAME SIZE_GB MODEL SERIAL ROTA DETAIL
  local a h p k s m se r d
  while IFS='|' read -r a h p k s m se r d; do
    [ -n "$a" ] || continue; [[ $a == \#* ]] && continue
    [[ $s =~ ^[0-9]+$ ]] && s=$((s/1000000000))
    printf '%-9s %-8s %-48s %-8s %8s %-22s %-16s %-4s %s\n' "$a" "$h" "${p#/dev/disk/by-id/}" "$k" "$s" "$m" "$se" "$r" "$d"
  done
  echo
}

# stdin: plan lines. Answers are read from fd 3 (opened on /dev/tty by caller).
confirm_plan() {
  local plan n ans a h p k s m se r d want
  plan=$(cat)
  if [ "${FDC_CONFIRM_ALLOW_NONTTY:-0}" != 1 ]; then
    [ -t 3 ] || { echo "typed confirmation needs a terminal (no tty on fd 3)" >&2; return 1; }
  fi
  n=$(grep -cE '^(CREATE|NEEDS-ZAP)\|' <<<"$plan" || true)
  [ "$n" -gt 0 ] || { echo "nothing to create" >&2; return 1; }
  printf 'About to WIPE and create %s OSD(s). Type YES-WIPE-%s to continue: ' "$n" "$n" >&2
  read -r ans <&3 || return 1
  [ "$ans" = "YES-WIPE-$n" ] || { echo "confirmation mismatch, aborting" >&2; return 1; }
  while IFS='|' read -r a h p k s m se r d; do
    [ "$a" = NEEDS-ZAP ] || continue
    want=${se: -4}
    [ "${#se}" -ge 4 ] && [ "$se" != "-" ] || { echo "$h $p has no usable serial; zap it by hand" >&2; return 1; }
    printf '%s %s (%s) has OLD DATA [%s]. Type last 4 chars of serial to zap: ' "$h" "$p" "$k" "$d" >&2
    read -r ans <&3 || return 1
    [ "$ans" = "$want" ] || { echo "serial mismatch for $h $p, aborting" >&2; return 1; }
  done <<<"$plan"
  return 0
}

# Remote probe: copy OUR disk-safety.sh to the node and execute it by path (never
# `bash -s` / script on ssh stdin, which breaks under ssh -n). Path defaults to
# $BUNDLE_DIR/offline/disk-safety.sh (override REMOTE_DISK_SAFETY).
# The caller runs us as `probe_host ... || die`, which disables set -e in here, so every
# step checks its own status explicitly. Copy is scp to <path>.tmp.<pid> (<pid> = this
# add-osds.sh process on node1), then chmod+mv over the final path; if the scp or the
# chmod/mv fails we best-effort remove the .tmp on the node and return 1 WITHOUT running
# anything, so neither a partial copy nor a stale old copy is executed.
probe_host() { # host path... -> snapshot on stdout; non-zero on any failure
  local h=$1; shift
  local ip remote tmp q_dir q_tmp q_remote args
  if [ "$h" = "$(hostname -s)" ]; then
    bash "$HERE/disk-safety.sh" probe "$@" || return 1
    return 0
  fi
  ip=$(node_ip "$h") || return 1
  [ -n "$ip" ] || { echo "probe_host: no IP for $h" >&2; return 1; }
  remote=${REMOTE_DISK_SAFETY:-$BUNDLE_DIR/offline/disk-safety.sh}
  # scp's remote path may or may not go through a remote shell (SFTP vs legacy mode), so
  # restrict it to a plain absolute path instead of relying on quoting there.
  [[ $remote =~ ^/[A-Za-z0-9._/+-]+$ ]] || { echo "probe_host: unsafe REMOTE_DISK_SAFETY path: $remote" >&2; return 1; }
  tmp="$remote.tmp.$$"
  q_dir=$(printf '%q' "$(dirname "$remote")"); q_tmp=$(printf '%q' "$tmp"); q_remote=$(printf '%q' "$remote")
  args=$(printf '%q ' "$@")
  ssh_node "$ip" "mkdir -p $q_dir" \
    || { echo "probe_host: mkdir $remote dir failed on $h" >&2; return 1; }
  if ! scp -q "${SSH_OPTS[@]}" "$HERE/disk-safety.sh" "root@$ip:$tmp"; then
    echo "probe_host: scp disk-safety.sh to $h failed" >&2
    ssh_node "$ip" "rm -f $q_tmp" || true
    return 1
  fi
  if ! ssh_node "$ip" "chmod 0755 $q_tmp && mv -f $q_tmp $q_remote"; then
    echo "probe_host: install $remote on $h failed (chmod/mv)" >&2
    ssh_node "$ip" "rm -f $q_tmp" || true
    return 1
  fi
  ssh_node "$ip" "bash $q_remote probe $args" || return 1
}

[ "${1:-}" = --source-only ] && return 0 2>/dev/null

MODE=preview; ONLY=""; SKIP_REFUSED=0; PLAN_FILE=""
while [ $# -gt 0 ]; do
  case $1 in
    --yes-i-really-mean-it) MODE=legacy;;
    --confirm) MODE=confirm;;
    --apply-plan) MODE=apply; PLAN_FILE=$2; shift;;
    --plan) PLAN_FILE=$2; shift;;
    --host) ONLY=$2; shift;;
    --skip-refused) SKIP_REFUSED=1;;
    --dry-run) DRY_RUN=1;;
    -h|--help) sed -n '2,16p' "$0"; exit 0;;
    *) die "unknown arg $1";;
  esac; shift
done
need_root; load_conf
[ "${#OSD_DEVICES[@]}" -gt 0 ] || die "OSD_DEVICES empty"
mkdir -p "$STATE_DIR"
PLAN_FILE=${PLAN_FILE:-$STATE_DIR/osd-plan.txt}
FSID=$(awk '$1=="fsid"{print $3}' /etc/ceph/ceph.conf 2>/dev/null || true)

classify_all() {
  local h e d hosts=() paths snap
  for e in "${OSD_DEVICES[@]}"; do h=${e%%:*}; [[ " ${hosts[*]} " == *" $h "* ]] || hosts+=("$h"); done
  for h in "${hosts[@]}"; do
    [ -n "$ONLY" ] && [ "$h" != "$ONLY" ] && continue
    node_ip "$h" >/dev/null || die "OSD_DEVICES host $h not in NODE_NAMES"
    paths=()
    for e in "${OSD_DEVICES[@]}"; do
      [ "${e%%:*}" = "$h" ] || continue
      d=${e#*:}; d=${d%%:*}   # strip optional :class
      paths+=("/${d#/}")
    done
    snap=$(mktemp); probe_host "$h" "${paths[@]}" > "$snap" || { rm -f "$snap"; die "probe failed on $h (root ssh?)"; }
    bash "$HERE/disk-safety.sh" classify "$snap" "$h" ${FSID:+--fsid "$FSID"} "${paths[@]}"
    rm -f "$snap"
  done
}

log "orchestrator device inventory:"
ceph_ orch device ls --wide --refresh || true
CUR=$(classify_all)
print_plan <<<"$CUR"
NREF=$(grep -c '^REFUSE|' <<<"$CUR" || true)
NNEW=$(grep -cE '^(CREATE|NEEDS-ZAP)\|' <<<"$CUR" || true)
log "CREATE/NEEDS-ZAP: $NNEW   SKIP: $(grep -c '^SKIP|' <<<"$CUR" || true)   REFUSE: $NREF"

if [ "$MODE" = preview ]; then
  log "PREVIEW only. Next: ./add-osds.sh --confirm   (then --apply-plan $PLAN_FILE)"
  exit 0
fi

if [ "$MODE" = confirm ] || [ "$MODE" = legacy ]; then
  if [ "$NREF" -gt 0 ] && [ "$SKIP_REFUSED" -eq 0 ]; then
    die "$NREF device(s) REFUSED (see table). Fix OSD_DEVICES or rerun with --skip-refused (refused disks are never touched)"
  fi
  [ "$NNEW" -gt 0 ] || { log "nothing to create"; : > "$PLAN_FILE"; exit 0; }
  if [ "$DRY_RUN" = 1 ]; then log "[dry-run] would ask: YES-WIPE-$NNEW + serial tails; no plan written"; exit 0; fi
  exec 3</dev/tty || die "no terminal for typed confirmation"
  grep -E '^(CREATE|NEEDS-ZAP)\|' <<<"$CUR" | confirm_plan || die "not confirmed; nothing changed"
  exec 3<&-
  { echo "# fast-deploy osd plan; fsid=${FSID:-unknown}; confirmed $(date -Is) on $(tty 2>/dev/null || echo tty)"
    grep -E '^(CREATE|NEEDS-ZAP)\|' <<<"$CUR"; } > "$PLAN_FILE"
  log "confirmed plan written: $PLAN_FILE"
  [ "$MODE" = confirm ] && exit 0
fi

# --- apply (only what is in the confirmed plan, re-validated now) ---------------
[ -s "$PLAN_FILE" ] || die "plan $PLAN_FILE missing/empty: run ./add-osds.sh --confirm first"
head -n1 "$PLAN_FILE" | grep -q '^# fast-deploy osd plan; .*confirmed' || die "plan $PLAN_FILE is not a confirmed plan"
BEFORE=$(ceph_ osd stat --format json 2>/dev/null | jq -r '.num_up_osds // 0' || echo 0)
N=0
while IFS='|' read -r a h p k s m se r d; do
  [[ -z $a || $a == \#* ]] && continue
  now=$(awk -F'|' -v h="$h" -v p="$p" '$2==h && $3==p' <<<"$CUR")
  [ -n "$now" ] || die "$h $p no longer in OSD_DEVICES/probe; re-confirm"
  IFS='|' read -r na _ _ nk _ _ nse _ nd <<<"$now"
  [ "$nk" = "$k" ] && [ "$nse" = "$se" ] || die "$h $p changed (kname/serial $k/$se -> $nk/$nse); re-confirm"
  case "$a:$na" in
    CREATE:CREATE|NEEDS-ZAP:NEEDS-ZAP|NEEDS-ZAP:CREATE) ;;
    *:SKIP) log "$h $p already an OSD, skip"; continue;;
    *) die "$h $p now $na ($nd); planned $a. Refusing.";;
  esac
  # cephadm shell (via ceph_) inherits stdin; without </dev/null it would drain the
  # remaining lines of PLAN_FILE under `done < "$PLAN_FILE"` and only create osd.0.
  if [ "$a" = NEEDS-ZAP ]; then run ceph_ orch device zap "$h" "$p" --force </dev/null; fi
  run ceph_ orch daemon add osd "$h:$p" </dev/null
  N=$((N+1))
done < "$PLAN_FILE"
[ "$DRY_RUN" = 1 ] && exit 0
WANT=$((BEFORE+N)); t=0
log "waiting for $WANT OSDs up (timeout ${OSD_UP_TIMEOUT}s)"
until [ "$(ceph_ osd stat --format json | jq -r .num_up_osds)" -ge "$WANT" ]; do
  t=$((t+15)); [ "$t" -le "$OSD_UP_TIMEOUT" ] || die "timeout waiting for $WANT OSDs up"
  sleep 15
done
ceph_ osd tree
ceph_ osd stat
