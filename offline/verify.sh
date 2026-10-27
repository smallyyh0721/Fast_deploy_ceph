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
[ "$ENABLE_MON_VIP" = 1 ] && echo "  mon VIP:  $VIP_ADDR (check: ip -br addr | grep $VIP_ADDR on nodes)"
echo "  monitors: $(IFS=,; echo "${NODE_IPS[*]:0:3}") (port 3300/6789) — use for CSI / clients"
[ "$FAIL" = 0 ] || die "verify: problems found (see above)"
[ "$H" = HEALTH_OK ] || warn "health is $H (WARN may be transient, e.g. right after pool creation)"
log "verify: OK"
