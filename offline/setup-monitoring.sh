#!/usr/bin/env bash
# Monitoring stack + Ceph dashboard from the LOCAL registry (deploy.sh stage "monitoring").
#   sudo ./setup-monitoring.sh [--dry-run]       # run on node1; idempotent
#   sudo ./deploy.sh --only monitoring           # same, also to retrofit an existing cluster
# Deploys (ENABLE_MONITORING=1, default): ceph-exporter + node-exporter (every host), prometheus,
#   alertmanager (ENABLE_ALERTMANAGER=1), grafana (MONITORING_HOSTS or count:1); mgr prometheus module.
# Dashboard (ENABLE_DASHBOARD=1, default): HTTPS on DASHBOARD_PORT (8443); DASHBOARD_CERT/KEY or a
#   self-signed cert; admin password read from DASHBOARD_ADMIN_PASSWORD_FILE (generated there,
#   mode 600, if missing) and passed on stdin -- never printed, never on argv.
# Alerts: NO webhook / SMTP receivers are configured. Metrics are exported for external scraping
#   (ports + scrape example: docs/monitoring.md).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
for a in "$@"; do case $a in --dry-run) DRY_RUN=1;; -h|--help) sed -n '2,12p' "$0"; exit 0;; *) die "unknown arg $a";; esac; done
load_conf

# ---- checks (also used in dry-run) --------------------------------------------------
monitoring_check_conf() {
  local e=0 h n ok
  [[ $PROMETHEUS_RETENTION_TIME =~ ^[0-9]+(y|w|d|h|m|s)$ ]] || { warn "PROMETHEUS_RETENTION_TIME '$PROMETHEUS_RETENTION_TIME' invalid (e.g. 15d, 8w, 1y)"; e=1; }
  [[ $PROMETHEUS_RETENTION_SIZE =~ ^(0|[0-9]+(B|KB|MB|GB|TB|PB|EB))$ ]] || { warn "PROMETHEUS_RETENTION_SIZE '$PROMETHEUS_RETENTION_SIZE' invalid (0 = off, or e.g. 50GB)"; e=1; }
  [[ $DASHBOARD_PORT =~ ^[0-9]+$ ]] && [ "$DASHBOARD_PORT" -ge 1 ] && [ "$DASHBOARD_PORT" -le 65535 ] || { warn "DASHBOARD_PORT '$DASHBOARD_PORT' invalid"; e=1; }
  [[ $SD_PORT =~ ^[0-9]+$ ]] && [ "$SD_PORT" -ge 1 ] && [ "$SD_PORT" -le 65535 ] || { warn "SD_PORT '$SD_PORT' invalid"; e=1; }
  case $GRAFANA_API_SSL_VERIFY in True|False) ;; *) warn "GRAFANA_API_SSL_VERIFY must be True or False"; e=1;; esac
  { [ -n "$DASHBOARD_CERT" ] && [ -z "$DASHBOARD_KEY" ]; } || { [ -z "$DASHBOARD_CERT" ] && [ -n "$DASHBOARD_KEY" ]; } && { warn "set both DASHBOARD_CERT and DASHBOARD_KEY (or neither = self-signed)"; e=1; }
  [[ $DASHBOARD_ADMIN_USER =~ ^[A-Za-z0-9._-]+$ ]] || { warn "DASHBOARD_ADMIN_USER invalid"; e=1; }
  [[ $DASHBOARD_ADMIN_PASSWORD_FILE == /* ]] || { warn "DASHBOARD_ADMIN_PASSWORD_FILE must be an absolute path"; e=1; }
  [ -z "$GRAFANA_FRONTEND_API_URL" ] || [[ $GRAFANA_FRONTEND_API_URL =~ ^https?://[^[:space:]]+$ ]] || { warn "GRAFANA_FRONTEND_API_URL must be http(s)://..."; e=1; }
  for h in "${MONITORING_HOSTS[@]}"; do
    ok=0; for n in "${NODE_NAMES[@]}"; do [ "$n" = "$h" ] && ok=1; done
    [ "$ok" = 1 ] || { warn "MONITORING_HOSTS: $h not in NODE_NAMES"; e=1; }
  done
  return "$e"
}

placement_yaml() {
  local h
  if [ "${#MONITORING_HOSTS[@]}" -gt 0 ]; then
    echo "placement:"; echo "  hosts:"; for h in "${MONITORING_HOSTS[@]}"; do echo "  - $h"; done
  else
    echo "placement:"; echo "  count: 1"
  fi
}
# YAML single-quoted scalar
yq1() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }

# Service specs. $1 = grafana admin password ("" = none; anonymous viewer access stays on).
monitoring_spec() {
  local gpw=${1:-}
  cat <<EOF
service_type: ceph-exporter
placement:
  host_pattern: '*'
---
service_type: node-exporter
placement:
  host_pattern: '*'
---
service_type: prometheus
$(placement_yaml)
spec:
  retention_time: "$PROMETHEUS_RETENTION_TIME"
  retention_size: "$PROMETHEUS_RETENTION_SIZE"
EOF
  if [ "$ENABLE_ALERTMANAGER" = 1 ]; then
    printf -- '---\nservice_type: alertmanager\n%s\n' "$(placement_yaml)"
  fi
  printf -- '---\nservice_type: grafana\n%s\n' "$(placement_yaml)"
  if [ -n "$gpw" ]; then printf 'spec:\n  initial_admin_password: %s\n' "$(yq1 "$gpw")"; fi
}

if [ "$ENABLE_MONITORING" != 1 ] && [ "$ENABLE_DASHBOARD" != 1 ]; then
  log "ENABLE_MONITORING=0 and ENABLE_DASHBOARD=0, nothing to do"; exit 0
fi
monitoring_check_conf || die "monitoring settings invalid (see above)"

IMG_KEYS=(prometheus:"$PROMETHEUS_IMAGE" alertmanager:"$ALERTMANAGER_IMAGE" node_exporter:"$NODE_EXPORTER_IMAGE" grafana:"$GRAFANA_IMAGE")

if [ "$DRY_RUN" = 1 ]; then
  for kv in "${IMG_KEYS[@]}"; do echo "  [dry-run] ceph config set mgr mgr/cephadm/container_image_${kv%%:*} ${kv#*:}"; done
  if [ "$ENABLE_MONITORING" = 1 ]; then
    echo "  [dry-run] check local registry $REGISTRY has: $PROMETHEUS_IMAGE $ALERTMANAGER_IMAGE $NODE_EXPORTER_IMAGE $GRAFANA_IMAGE"
    echo "  [dry-run] ceph mgr module enable prometheus   (mgr metrics :9283)"
    echo "  [dry-run] ceph config set mgr mgr/cephadm/service_discovery_port $SD_PORT"
    echo "  [dry-run] ceph orch apply -i - <<spec (no webhook/SMTP receivers)"
    gp=""; [ -n "$GRAFANA_ADMIN_PASSWORD_FILE" ] && gp="<read from $GRAFANA_ADMIN_PASSWORD_FILE>"
    monitoring_spec "$gp" | sed 's/^/      /'
  else
    log "ENABLE_MONITORING=0: monitoring services not deployed"
  fi
  if [ "$ENABLE_DASHBOARD" = 1 ]; then
    echo "  [dry-run] ceph config set mgr mgr/dashboard/ssl true; mgr/dashboard/ssl_server_port $DASHBOARD_PORT; mgr module enable dashboard"
    if [ -n "$DASHBOARD_CERT" ]; then echo "  [dry-run] ceph dashboard set-ssl-certificate / -key -i - < $DASHBOARD_CERT / $DASHBOARD_KEY"
    else echo "  [dry-run] ceph dashboard create-self-signed-cert (only if no cert is stored yet)"; fi
    echo "  [dry-run] admin '$DASHBOARD_ADMIN_USER': password from $DASHBOARD_ADMIN_PASSWORD_FILE (generate 600 if missing) via stdin; create only if the user does not exist"
    echo "  [dry-run] ceph dashboard set-grafana-api-ssl-verify $GRAFANA_API_SSL_VERIFY"
    [ -n "$GRAFANA_FRONTEND_API_URL" ] && echo "  [dry-run] ceph dashboard set-grafana-frontend-api-url $GRAFANA_FRONTEND_API_URL"
    echo "  [dry-run] ceph mgr module disable/enable dashboard (apply port/cert)"
  else
    log "ENABLE_DASHBOARD=0: dashboard not configured"
  fi
  exit 0
fi

need_root
[ "$(self_index)" -eq 0 ] || die "run on $ADMIN_NAME"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; chmod 700 "$TMP"

# images from the local registry (idempotent; bootstrap.sh sets the same keys)
for kv in "${IMG_KEYS[@]}"; do ceph_ config set mgr "mgr/cephadm/container_image_${kv%%:*}" "${kv#*:}"; done

if [ "$ENABLE_MONITORING" = 1 ]; then
  for img in "$PROMETHEUS_IMAGE" "$ALERTMANAGER_IMAGE" "$NODE_EXPORTER_IMAGE" "$GRAFANA_IMAGE"; do
    p=${img#"$REGISTRY"/}; repo=${p%:*}; tag=${p##*:}
    curl -fsS "http://$REGISTRY/v2/$repo/tags/list" 2>/dev/null | grep -q "\"$tag\"" \
      || die "local registry $REGISTRY has no $repo:$tag (bundle >= oneclick.3 + ./install-node.sh on $ADMIN_NAME)"
  done
  log "mgr prometheus module (:9283) + cephadm service discovery (:$SD_PORT)"
  ceph_ mgr module enable prometheus
  ceph_ config set mgr mgr/cephadm/service_discovery_port "$SD_PORT"
  [ "$(ceph_ config get mgr mgr/cephadm/secure_monitoring_stack 2>/dev/null)" = true ] \
    && warn "mgr/cephadm/secure_monitoring_stack=true: exporters need TLS/basic auth for external scrapers (docs/monitoring.md)"
  gpw=""
  if [ -n "$GRAFANA_ADMIN_PASSWORD_FILE" ]; then
    [ -s "$GRAFANA_ADMIN_PASSWORD_FILE" ] || die "GRAFANA_ADMIN_PASSWORD_FILE $GRAFANA_ADMIN_PASSWORD_FILE missing/empty"
    gpw=$(head -n1 "$GRAFANA_ADMIN_PASSWORD_FILE")
  fi
  ( umask 077; monitoring_spec "$gpw" > "$TMP/monitoring.yaml" ); unset gpw
  log "ceph orch apply: ceph-exporter node-exporter prometheus$([ "$ENABLE_ALERTMANAGER" = 1 ] && echo ' alertmanager') grafana (retention ${PROMETHEUS_RETENTION_TIME}/${PROMETHEUS_RETENTION_SIZE})"
  ceph_in "$TMP/monitoring.yaml" orch apply -i -
  rm -f "$TMP/monitoring.yaml"
fi

if [ "$ENABLE_DASHBOARD" = 1 ]; then
  log "dashboard: HTTPS :$DASHBOARD_PORT"
  ceph_ config set mgr mgr/dashboard/ssl true
  ceph_ config set mgr mgr/dashboard/ssl_server_port "$DASHBOARD_PORT"
  ceph_ mgr module enable dashboard
  for _ in $(seq 1 30); do ceph_ dashboard get-grafana-api-ssl-verify >/dev/null 2>&1 && break; sleep 2; done
  if [ -n "$DASHBOARD_CERT" ]; then
    [ -r "$DASHBOARD_CERT" ] && [ -r "$DASHBOARD_KEY" ] || die "DASHBOARD_CERT/KEY not readable"
    log "dashboard: certificate from $DASHBOARD_CERT"
    ceph_in "$DASHBOARD_CERT" dashboard set-ssl-certificate -i - >/dev/null
    ceph_in "$DASHBOARD_KEY" dashboard set-ssl-certificate-key -i - >/dev/null
  elif ceph_ config-key exists mgr/dashboard/crt >/dev/null 2>&1; then
    log "dashboard: certificate already stored, kept"
  else
    log "dashboard: self-signed certificate"
    ceph_ dashboard create-self-signed-cert >/dev/null
  fi
  PWF=$DASHBOARD_ADMIN_PASSWORD_FILE
  if [ ! -s "$PWF" ]; then
    ( umask 077; mkdir -p "$(dirname "$PWF")"; pw=$(head -c 96 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9'); printf '%s\n' "${pw:0:24}" > "$PWF" )
    log "dashboard: generated admin password into $PWF (mode 600; not printed)"
  fi
  chmod 600 "$PWF"
  if ceph_ dashboard ac-user-show "$DASHBOARD_ADMIN_USER" >/dev/null 2>&1; then
    if [ "${DASHBOARD_RESET_PASSWORD:-0}" = 1 ]; then
      head -n1 "$PWF" | tr -d '\n' > "$TMP/pw"
      ceph_in "$TMP/pw" dashboard ac-user-set-password "$DASHBOARD_ADMIN_USER" -i - --force-password >/dev/null
      log "dashboard: password of '$DASHBOARD_ADMIN_USER' reset from $PWF"
    else
      log "dashboard: user '$DASHBOARD_ADMIN_USER' exists, password unchanged (DASHBOARD_RESET_PASSWORD=1 to set it from $PWF)"
    fi
  else
    head -n1 "$PWF" | tr -d '\n' > "$TMP/pw"
    ceph_in "$TMP/pw" dashboard ac-user-create "$DASHBOARD_ADMIN_USER" -i - administrator --force-password >/dev/null
    log "dashboard: created administrator '$DASHBOARD_ADMIN_USER' (password in $PWF)"
  fi
  rm -f "$TMP/pw"
  ceph_ dashboard set-grafana-api-ssl-verify "$GRAFANA_API_SSL_VERIFY" >/dev/null
  [ -z "$GRAFANA_FRONTEND_API_URL" ] || ceph_ dashboard set-grafana-frontend-api-url "$GRAFANA_FRONTEND_API_URL" >/dev/null
  ceph_ mgr module disable dashboard; ceph_ mgr module enable dashboard
fi

ceph_ mgr services || true
ceph_ orch ls || true
log "setup-monitoring done (services may take a few minutes; check with ./verify.sh)"
