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
  exit 0
fi
need_root
for c in "${CHECKS[@]}"; do log "$c"; read -ra w <<<"$c"; cephadm shell -- "${w[@]}" || true; done
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
[ "$ENABLE_MON_VIP" = 1 ] && echo "  mon VIP:  $VIP_ADDR (check: ip -br addr | grep $VIP_ADDR on nodes)"
echo "  monitors: $(IFS=,; echo "${NODE_IPS[*]:0:3}") (port 3300/6789) — use for CSI / clients"
[ "$FAIL" = 0 ] || die "verify: problems found (see above)"
[ "$H" = HEALTH_OK ] || warn "health is $H (WARN may be transient, e.g. right after pool creation)"
log "verify: OK"
