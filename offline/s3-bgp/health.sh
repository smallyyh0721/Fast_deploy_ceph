#!/usr/bin/env bash
# fast-deploy-s3-bgp health controller: announce VIP/32 via FRR only while the existing
# cephadm ingress (HAProxy) + local RGW are healthy.
#   health.sh run        main loop (systemd Type=notify, watchdog)
#   health.sh check      one evaluation, prints result, exit 0 healthy / 1 not
#   health.sh withdraw   remove "network VIP/32" (idempotent)
#   health.sh parse-stats <csv-file>    (unit tests) -> "frontend=<status> backend_up=<n>"
# Healthy = frontend <S3_BGP_FRONTEND_NAME>/FRONTEND status OPEN
#         + >=1 server in backend <S3_BGP_BACKEND_NAME> whose name starts with
#           <S3_BGP_BACKEND_SERVER_PREFIX> and status UP*
#         + local probe (S3_BGP_PROBE_MODE: anon-xml | http-status | tcp | none) OK.
# Secrets (HAProxy "stats auth") are read from haproxy.cfg at runtime, passed to curl on
# stdin (-K -) and never logged.
set -euo pipefail
NODE_CONF=${S3_BGP_NODE_CONF:-/etc/fast-deploy-s3-bgp/s3-bgp.conf}
DISABLE_FLAG=${S3_BGP_DISABLE_FLAG:-/run/fast-deploy-s3-bgp.disabled}
STATE_FILE=${S3_BGP_HEALTH_STATE:-/run/fast-deploy-s3-bgp-health.state}
VTYSH=${VTYSH:-vtysh}

hlog() { echo "s3-bgp-health: $*" >&2; }

# CSV from "show stat" / "/stats;csv": header "# pxname,svname,...,status,..."
parse_stats() {
  awk -F, -v fe="${S3_BGP_FRONTEND_NAME:-frontend}" -v be="${S3_BGP_BACKEND_NAME:-backend}" \
      -v pfx="${S3_BGP_BACKEND_SERVER_PREFIX:-rgw.}" '
    NR==1 || /^# / { sub(/^# */, ""); for (i=1;i<=NF;i++) col[$i]=i; next }
    !("status" in col) { next }
    { st=$col["status"] }
    $col["pxname"]==fe && $col["svname"]=="FRONTEND" { festat=st }
    $col["pxname"]==be && index($col["svname"], pfx)==1 && st ~ /^UP/ { up++ }
    END { if (!("status" in col)) { print "frontend=NOHEADER backend_up=0"; exit }
          printf "frontend=%s backend_up=%d\n", (festat==""?"MISSING":festat), up }' "$1"
}

# path given explicitly, else newest match of the glob (cephadm path contains fsid + random suffix)
discover_haproxy_cfg() {
  local f newest=""
  if [ -n "${S3_BGP_HAPROXY_CFG:-}" ]; then echo "$S3_BGP_HAPROXY_CFG"; return 0; fi
  # shellcheck disable=SC2086
  for f in $S3_BGP_HAPROXY_GLOB; do
    [ -f "$f" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi
  done
  [ -n "$newest" ] || return 1
  echo "$newest"
}

stats_auth() { awk '$1=="stats" && $2=="auth" {print $3; exit}' "$1"; }

fetch_stats() {   # $1=cfg $2=outfile
  local auth
  auth=$(stats_auth "$1" || true)
  if [ -n "$auth" ]; then
    printf 'user = "%s"\n' "$auth" | curl -fsS -m 2 --noproxy '*' --max-filesize 1048576 -K - \
      -o "$2" "$S3_BGP_STATS_URL" 2>/dev/null
  else
    curl -fsS -m 2 --noproxy '*' --max-filesize 1048576 -o "$2" "$S3_BGP_STATS_URL" 2>/dev/null
  fi
}

probe_ok() {
  local code body
  case ${S3_BGP_PROBE_MODE:-anon-xml} in
    none) return 0;;
    tcp)
      local hp=${S3_BGP_PROBE_URL#*://}; hp=${hp%%/*}
      timeout 2 bash -c ": </dev/tcp/${hp%:*}/${hp##*:}" 2>/dev/null;;
    http-status)
      code=$(curl -s -m 2 --noproxy '*' -o /dev/null -w '%{http_code}' "$S3_BGP_PROBE_URL" || true)
      [[ " ${S3_BGP_PROBE_CODES:-200 403} " == *" $code "* ]];;
    anon-xml)
      body=$(curl -s -m 2 --noproxy '*' --max-filesize 1048576 -w '\n%{http_code}' "$S3_BGP_PROBE_URL" || true)
      [ "${body##*$'\n'}" = 200 ] && [[ $body == *"${S3_BGP_PROBE_EXPECT:-ListAllMyBucketsResult}"* ]];;
    *) hlog "unknown S3_BGP_PROBE_MODE=${S3_BGP_PROBE_MODE}"; return 1;;
  esac
}

# evaluate once; sets REASON; returns 0 healthy
REASON=""
evaluate() {
  local cfg tmp res
  if [ -e "$DISABLE_FLAG" ]; then REASON="maintenance flag $DISABLE_FLAG"; return 1; fi
  cfg=$(discover_haproxy_cfg) || { REASON="haproxy.cfg not found ($S3_BGP_HAPROXY_GLOB)"; return 1; }
  tmp=$(mktemp)
  if ! fetch_stats "$cfg" "$tmp"; then rm -f "$tmp"; REASON="haproxy stats unreachable"; return 1; fi
  res=$(parse_stats "$tmp"); rm -f "$tmp"
  case $res in
    "frontend=OPEN backend_up=0") REASON="$res"; return 1;;
    "frontend=OPEN "*) ;;
    *) REASON="$res"; return 1;;
  esac
  probe_ok || { REASON="$res, local probe ${S3_BGP_PROBE_MODE} failed"; return 1; }
  REASON="$res, probe ok"
  return 0
}

bgp_network() {   # $1 = add|del
  local out rc=0 neg=""
  [ "$1" = del ] && neg="no "
  out=$($VTYSH -c 'configure terminal' -c "router bgp $S3_BGP_LOCAL_ASN" \
        -c 'address-family ipv4 unicast' -c "${neg}network ${S3_BGP_VIP}/32" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && [ "$1" = del ] && [[ $out == *"Can't find"* ]]; then rc=0; fi
  [ "$rc" -eq 0 ] || hlog "vtysh ${neg}network failed rc=$rc: $out"
  return "$rc"
}

# rise/fall state machine: step <good:0|1>; globals ADV GOOD BAD; sets ACTION
ADV=0; GOOD=0; BAD=0; ACTION=keep
step() {
  if [ "$1" = 1 ]; then GOOD=$((GOOD+1)); BAD=0; else BAD=$((BAD+1)); GOOD=0; fi
  ACTION=keep
  if [ "$ADV" = 0 ] && [ "$GOOD" -ge "${S3_BGP_RISE:-3}" ]; then ADV=1; ACTION=advertise
  elif [ "$ADV" = 1 ] && [ "$BAD" -ge "${S3_BGP_FALL:-2}" ]; then ADV=0; ACTION=withdraw; fi
}

write_state() {
  printf 'advertised=%s good=%s bad=%s ts=%s reason=%s\n' "$ADV" "$GOOD" "$BAD" "$(date +%s)" "$REASON" \
    > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

notify() { [ -z "${NOTIFY_SOCKET:-}" ] || systemd-notify "$@" 2>/dev/null || true; }

run_loop() {
  local ok last=""
  trap 'bgp_network del || true; ADV=0; REASON="stopped"; write_state; exit 0' TERM INT
  bgp_network del || true
  notify --ready
  while :; do
    if evaluate; then ok=1; else ok=0; fi
    step "$ok"
    case $ACTION in
      advertise) bgp_network add && hlog "ADVERTISE ${S3_BGP_VIP}/32 ($REASON)";;
      withdraw) bgp_network del || true; hlog "WITHDRAW ${S3_BGP_VIP}/32 ($REASON)";;
      keep) if [ "$ADV" = 1 ]; then bgp_network add >/dev/null || true; fi;;  # re-assert after frr restart
    esac
    if [ "$ok" = 0 ] && [ "$REASON" != "$last" ]; then hlog "unhealthy: $REASON"; fi
    last=$REASON
    write_state
    notify WATCHDOG=1 "STATUS=advertised=$ADV $REASON"
    sleep "${S3_BGP_INTERVAL:-2}"
  done
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  cmd=${1:-}
  if [ "$cmd" = parse-stats ]; then parse_stats "${2:?csv file}"; exit 0; fi
  # shellcheck source=/dev/null
  . "$NODE_CONF"
  case $cmd in
    run) run_loop;;
    check) if evaluate; then echo "HEALTHY: $REASON"; else echo "UNHEALTHY: $REASON"; exit 1; fi;;
    withdraw) bgp_network del;;
    *) echo "usage: $0 run|check|withdraw|parse-stats <csv>" >&2; exit 2;;
  esac
fi
