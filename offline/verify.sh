#!/usr/bin/env bash
# Post-deploy acceptance (stage 10). Read-only. Run on node1.
#   sudo ./verify.sh [--dry-run]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
for a in "$@"; do case $a in --dry-run) DRY_RUN=1;; *) die "unknown arg $a";; esac; done
load_conf
CHECKS=(
  "ceph -s" "ceph health detail" "ceph osd tree" "ceph osd pool ls detail" "ceph orch ls" "ceph orch ps"
)
[ "$ENABLE_CEPHFS" = 1 ] && CHECKS+=("ceph fs status $FS_NAME")
if [ "$DRY_RUN" = 1 ]; then
  for c in "${CHECKS[@]}"; do echo "  [dry-run] cephadm shell -- $c"; done
  [ "$ENABLE_RGW" = 1 ] && echo "  [dry-run] curl S3 endpoint (expect ListAllMyBucketsResult/AccessDenied XML)"
  if [ "$ENABLE_MONITORING" = 1 ]; then
    echo "  [dry-run] wait <= ${MONITORING_WAIT:-300}s: orch ls ceph-exporter node-exporter prometheus$([ "$ENABLE_ALERTMANAGER" = 1 ] && echo ' alertmanager') grafana running == size"
    echo "  [dry-run] curl ceph-exporter :9926/metrics (ceph_*), mgr :9283/metrics, prometheus :9095/-/ready, SD :$SD_PORT/sd/prometheus/sd-config?service=ceph-exporter"
  fi
  [ "$ENABLE_DASHBOARD" = 1 ] && echo "  [dry-run] ceph mgr services -> dashboard URL (https :$DASHBOARD_PORT), curl -k expect 200"
  if [ "$ENABLE_S3_BGP" = 1 ]; then echo "  [dry-run] s3-bgp on ${S3_BGP_HOSTS[*]}: s3-bgp-health active, BGP peer $S3_BGP_PEER_IP state, advertised = only ${S3_BGP_VIP}/32, received = 0"; fi
  exit 0
fi
need_root
for c in "${CHECKS[@]}"; do log "$c"; read -ra w <<<"$c"; cephadm shell -- "${w[@]}" </dev/null || true; done
FAIL=0
H=$(ceph_ health --format json | jq -r .status)
UP=$(ceph_ osd stat --format json | jq -r .num_up_osds)
IN=$(ceph_ osd stat --format json | jq -r .num_in_osds)
WANT=${#OSD_DEVICES[@]}
echo; log "=== summary ==="
echo "  health:   $H"; [ "$H" = HEALTH_ERR ] && FAIL=1
echo "  OSDs:     $UP up / $IN in (configured devices: $WANT)"; [ "$UP" -ge "$WANT" ] || { warn "fewer OSDs up than configured"; FAIL=1; }
echo "  mons:     $(ceph_ mon stat 2>/dev/null | head -n1)"
for e in "${RBD_POOLS[@]}"; do n=${e%%:*}
  ceph_ osd pool ls | grep -qx "$n" && echo "  pool:     $n ok" || { echo "  pool:     $n MISSING"; FAIL=1; }
done
if [ "$ENABLE_RGW" = 1 ]; then
  if [ "$RGW_INGRESS" = 1 ]; then EP="http://${RGW_VIP}:${RGW_FRONTEND_PORT}"; else EP="http://$(node_ip "${RGW_HOSTS[0]}"):${RGW_PORT}"; fi
  if curl -s -m 5 "$EP" | grep -q -e ListAllMyBucketsResult -e '<Error>'; then echo "  rgw:      $EP answers S3"; else echo "  rgw:      $EP NOT answering"; FAIL=1; fi
fi
if [ "$ENABLE_S3_BGP" = 1 ]; then
  # node-local view only (the switch is never logged into): LOCAL-OK / PENDING-SWITCH / FAIL
  for h in "${S3_BGP_HOSTS[@]}"; do
    r=$(on_node "$h" "systemctl is-active s3-bgp-health 2>/dev/null; sed -n 's/^advertised=\([01]\).*reason=/adv=\1 /p' /run/fast-deploy-s3-bgp-health.state 2>/dev/null; \
      vtysh -c 'show bgp ipv4 unicast summary json' 2>/dev/null | jq -r '(.ipv4Unicast // .).peers[\"$S3_BGP_PEER_IP\"] | \"peer=\\(.state) pfxRcd=\\(.pfxRcd // 0)\"' 2>/dev/null; \
      vtysh -c 'show bgp ipv4 unicast neighbors $S3_BGP_PEER_IP advertised-routes json' 2>/dev/null | jq -r '\"advertised=\" + ((.advertisedRoutes // {}) | keys | join(\",\"))' 2>/dev/null" 2>/dev/null) || r="ssh failed"
    r=$(tr '\n' ' ' <<<"$r")
    if [[ $r != active* ]]; then st=FAIL; FAIL=1
    elif [[ $r =~ advertised=([^ ]+) ]] && [ "${BASH_REMATCH[1]}" != "${S3_BGP_VIP}/32" ]; then st=FAIL; FAIL=1
    elif [[ $r =~ pfxRcd=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" != 0 ]; then st=FAIL; FAIL=1
    elif [[ $r == *"adv=0"* ]]; then st=WITHDRAWN-UNHEALTHY; FAIL=1
    elif [[ $r != *peer=Established* ]]; then st=PENDING-SWITCH
    else st=LOCAL-OK; fi
    echo "  s3-bgp:   $h $st ($r)"
  done
fi
MGRSVC=$(ceph_ mgr services --format json 2>/dev/null || echo '{}')
if [ "$ENABLE_MONITORING" = 1 ]; then
  SVCS=(ceph-exporter node-exporter prometheus grafana); [ "$ENABLE_ALERTMANAGER" = 1 ] && SVCS+=(alertmanager)
  mon_state() { local s r z out=""; for s in "${SVCS[@]}"; do
      read -r r z < <(ceph_ orch ls "$s" --format json 2>/dev/null | jq -r '.[0].status | "\(.running // 0) \(.size // 0)"' 2>/dev/null || echo "0 0")
      out+="$s=${r:-0}/${z:-0} "; done; echo "$out"; }
  end=$(( $(date +%s) + ${MONITORING_WAIT:-300} ))
  while :; do
    st=$(mon_state); bad=0
    for kv in $st; do v=${kv#*=}; [ "${v%/*}" -ge 1 ] && [ "${v%/*}" = "${v#*/}" ] || bad=1; done
    [ "$bad" = 0 ] || [ "$(date +%s)" -ge "$end" ] && break; sleep 10
  done
  if [ "$bad" = 0 ]; then echo "  monitor:  $st"; else echo "  monitor:  NOT all running: $st"; FAIL=1; fi
  # ceph-exporter on node1 (every host runs one)
  n=$(curl -s -m 5 "http://${ADMIN_IP}:9926/metrics" | grep -c '^ceph_' || true)
  if [ "${n:-0}" -gt 0 ]; then echo "  exporter: http://${ADMIN_IP}:9926/metrics ok ($n ceph_* samples)"; else echo "  exporter: http://${ADMIN_IP}:9926/metrics NO ceph_* metrics"; FAIL=1; fi
  PURL=$(jq -r '.prometheus // empty' <<<"$MGRSVC")
  if [ -n "$PURL" ] && curl -s -m 5 "${PURL%/}/metrics" | grep -q '^ceph_health_status'; then echo "  mgr-prom: ${PURL%/}/metrics ok"
  else echo "  mgr-prom: ${PURL:-<no mgr prometheus url>} not serving ceph_health_status"; FAIL=1; fi
  MGRHOST=$(sed -E 's#^[a-z]+://\[?([^]/]+)\]?:[0-9]+.*#\1#' <<<"$PURL")
  if [ -n "$MGRHOST" ] && curl -s -m 5 "http://${MGRHOST}:${SD_PORT}/sd/prometheus/sd-config?service=ceph-exporter" | jq -e 'length > 0' >/dev/null 2>&1; then
    echo "  sd:       http://${MGRHOST}:${SD_PORT}/sd/prometheus/sd-config?service=ceph-exporter ok"
  else echo "  sd:       http://${MGRHOST:-?}:${SD_PORT}/sd/ not answering (active mgr)"; FAIL=1; fi
  PH=$(ceph_ orch ps --daemon_type prometheus --format json 2>/dev/null | jq -r '.[0].hostname // empty')
  PIP=$(node_ip "$PH" 2>/dev/null || echo "$PH")
  if [ -n "$PIP" ] && curl -s -m 5 "http://${PIP}:9095/-/ready" | grep -qi ready; then echo "  prometheus: http://${PIP}:9095 ready"
  else echo "  prometheus: http://${PIP:-?}:9095 not ready"; FAIL=1; fi
fi
if [ "$ENABLE_DASHBOARD" = 1 ]; then
  DURL=$(jq -r '.dashboard // empty' <<<"$MGRSVC")
  code=$( [ -n "$DURL" ] && curl -k -s -m 5 -o /dev/null -w '%{http_code}' "$DURL" || echo 000)
  if [ "$code" = 200 ]; then echo "  dashboard: $DURL (user $DASHBOARD_ADMIN_USER, password file $DASHBOARD_ADMIN_PASSWORD_FILE)"
  else echo "  dashboard: ${DURL:-<not in mgr services>} HTTP $code"; FAIL=1; fi
fi
[ "$ENABLE_MON_VIP" = 1 ] && echo "  mon VIP:  $VIP_ADDR (check: ip -br addr | grep $VIP_ADDR on nodes)"
echo "  monitors: $(IFS=,; echo "${NODE_IPS[*]:0:3}") (port 3300/6789) — use for CSI / clients"
[ "$FAIL" = 0 ] || die "verify: problems found (see above)"
[ "$H" = HEALTH_OK ] || warn "health is $H (WARN may be transient, e.g. right after pool creation)"
log "verify: OK"
