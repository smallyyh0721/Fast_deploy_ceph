#!/usr/bin/env bash
# Unit tests (no root, no ceph, no network) for monitoring/dashboard, image list handling,
# host deb pinning and backup-cluster-meta.sh. cephadm/curl/id/hostname are mocked via PATH.
# Run: ./tests/test-monitoring.sh
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd); O=$(cd "$T/.." && pwd); B=$(cd "$O/../build" 2>/dev/null && pwd || true)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
nok() { fail=$((fail+1)); echo "FAIL $*"; }
check() { if [ "$3" = "$2" ]; then ok "$1"; else nok "$1: got '$3' want '$2'"; fi; }
has()   { if [[ $3 == *"$2"* ]]; then ok "$1"; else nok "$1: missing '$2'"; fi; }
hasnt() { if [[ $3 != *"$2"* ]]; then ok "$1"; else nok "$1: unexpected '$2'"; fi; }
R=10.250.0.11:5000
mkconf() { local f=$1; shift; cp "$O/cluster.conf.example" "$f"; [ $# -eq 0 ] || printf "%s\n" "$@" >> "$f"; }
mkconf "$W/def.conf"
SM="$O/setup-monitoring.sh"

# ---- 1. images.list / lib helpers --------------------------------------------------------
# shellcheck source=../lib.sh
lib_out=$(CONF="$W/def.conf" bash -c ". '$O/lib.sh'; load_conf
  local_image_ref quay.io/ceph/ceph:v20.2.4; local_image_ref docker.io/library/registry:2; local_image_ref foo/bar:1
  echo \$PROMETHEUS_IMAGE_SRC \$ALERTMANAGER_IMAGE_SRC \$NODE_EXPORTER_IMAGE_SRC \$GRAFANA_IMAGE_SRC
  echo \$PROMETHEUS_IMAGE \$GRAFANA_IMAGE")
check "local_image_ref quay.io" "$R/ceph/ceph:v20.2.4" "$(sed -n 1p <<<"$lib_out")"
check "local_image_ref docker.io" "$R/library/registry:2" "$(sed -n 2p <<<"$lib_out")"
check "local_image_ref no registry host" "$R/foo/bar:1" "$(sed -n 3p <<<"$lib_out")"
check "monitoring defaults = cephadm 20.2.4 DefaultImages" \
  "quay.io/prometheus/prometheus:v3.6.0 quay.io/prometheus/alertmanager:v0.28.1 quay.io/prometheus/node-exporter:v1.9.1 quay.io/ceph/grafana:12.3.1" \
  "$(sed -n 4p <<<"$lib_out")"
check "local refs" "$R/prometheus/prometheus:v3.6.0 $R/ceph/grafana:12.3.1" "$(sed -n 5p <<<"$lib_out")"
if [ -n "$B" ] && [ -f "$B/images.list" ]; then
  ents=$(bash -c ". '$O/lib.sh'; images_list_entries '$B/images.list'")
  check "images.list: 8 entries" 8 "$(wc -l <<<"$ents")"
  for r in quay.io/prometheus/prometheus:v3.6.0 quay.io/prometheus/alertmanager:v0.28.1 quay.io/prometheus/node-exporter:v1.9.1 quay.io/ceph/grafana:12.3.1 quay.io/ceph/ceph:v20.2.4; do
    grep -q "|$r|" <<<"$ents" && ok "images.list has $r" || nok "images.list lacks $r"
  done
  bases=$(cut -d'|' -f3 <<<"$ents" | tr '\n' ' ')
  has "images.list base names match validate.sh/install-node.sh" "prometheus-v3.6.0 alertmanager-v0.28.1 node-exporter-v1.9.1 grafana-12.3.1" "$bases"
  printf '# c\n\nx|a/b:1|x-1|d\n  # indented\ny|c/d:2|y-2\n' > "$W/il"
  check "images_list_entries skips comments/blank, no trailing newline ok" "x|a/b:1|x-1 y|c/d:2|y-2" "$(bash -c ". '$O/lib.sh'; images_list_entries '$W/il'" | tr '\n' ' ' | sed 's/ $//')"
fi

# ---- 2. setup-monitoring.sh --dry-run ------------------------------------------------------
out=$(CONF="$W/def.conf" bash "$SM" --dry-run 2>&1); rc=$?
check "dry-run default rc" 0 "$rc"
for k in prometheus:prometheus/prometheus:v3.6.0 alertmanager:prometheus/alertmanager:v0.28.1 node_exporter:prometheus/node-exporter:v1.9.1 grafana:ceph/grafana:12.3.1; do
  has "container_image_${k%%:*} -> local registry" "mgr/cephadm/container_image_${k%%:*} $R/${k#*:}" "$out"
done
has "spec ceph-exporter on all hosts" "service_type: ceph-exporter" "$out"
has "spec node-exporter" "service_type: node-exporter" "$out"
has "spec retention default 15d" 'retention_time: "15d"' "$out"
has "spec retention size default 0" 'retention_size: "0"' "$out"
has "spec alertmanager" "service_type: alertmanager" "$out"
has "spec grafana count:1" "count: 1" "$out"
has "dashboard 8443" "ssl_server_port 8443" "$out"
has "self-signed when no cert" "create-self-signed-cert" "$out"
has "grafana ssl verify False" "set-grafana-api-ssl-verify False" "$out"
spec=$(grep '^      ' <<<"$out")
hasnt "spec: no webhook receivers" "webhook_urls" "$spec"
hasnt "spec: no smtp" "smtp" "$(tr 'A-Z' 'a-z' <<<"$spec")"
hasnt "spec: no alertmanager user_data" "user_data" "$spec"
hasnt "no initial_admin_password by default" "initial_admin_password" "$out"
mkconf "$W/c2.conf" 'PROMETHEUS_RETENTION_TIME=30d' 'PROMETHEUS_RETENTION_SIZE=50GB' 'MONITORING_HOSTS=(node2 node3)' 'ENABLE_ALERTMANAGER=0' \
  'GRAFANA_FRONTEND_API_URL=https://grafana.example:3000' 'DASHBOARD_PORT=9443' 'GRAFANA_ADMIN_PASSWORD_FILE=/root/g.pass'
out=$(CONF="$W/c2.conf" bash "$SM" --dry-run 2>&1)
has "retention_time override" 'retention_time: "30d"' "$out"
has "retention_size override" 'retention_size: "50GB"' "$out"
has "MONITORING_HOSTS placement" "$(printf '  hosts:\n        - node2\n        - node3')" "$out"
hasnt "ENABLE_ALERTMANAGER=0" "service_type: alertmanager" "$out"
has "grafana frontend url" "set-grafana-frontend-api-url https://grafana.example:3000" "$out"
has "dashboard port override" "ssl_server_port 9443" "$out"
has "grafana password placeholder only" "initial_admin_password: '<read from /root/g.pass>'" "$out"
for bad in 'PROMETHEUS_RETENTION_TIME=15days' 'PROMETHEUS_RETENTION_SIZE=10G' 'DASHBOARD_PORT=70000' 'DASHBOARD_CERT=/x.crt' \
           'MONITORING_HOSTS=(nodeX)' 'GRAFANA_API_SSL_VERIFY=no' 'DASHBOARD_ADMIN_PASSWORD_FILE=rel/path' 'GRAFANA_FRONTEND_API_URL=grafana:3000'; do
  mkconf "$W/bad.conf" "$bad"; CONF="$W/bad.conf" bash "$SM" --dry-run >/dev/null 2>&1; check "rejects $bad" 1 "$?"
  vout=$(CONF="$W/bad.conf" bash "$O/validate.sh" --offline 2>&1); [[ $vout == *"monitoring/dashboard settings invalid"* ]] && ok "validate.sh flags $bad" || nok "validate.sh misses $bad"
done
mkconf "$W/off.conf" 'ENABLE_MONITORING=0' 'ENABLE_DASHBOARD=0'
has "both off: nothing to do" "nothing to do" "$(CONF="$W/off.conf" bash "$SM" --dry-run 2>&1)"
mkconf "$W/donly.conf" 'ENABLE_MONITORING=0'
out=$(CONF="$W/donly.conf" bash "$SM" --dry-run 2>&1)
hasnt "dashboard only: no orch apply" "orch apply" "$out"; has "dashboard only: dashboard" "mgr/dashboard/ssl true" "$out"
has "validate.sh ok line" "monitoring=1 dashboard=1 (https :8443" "$(CONF="$W/def.conf" bash "$O/validate.sh" --offline 2>&1)"

# ---- 3. setup-monitoring.sh apply with mocks ------------------------------------------------
M="$W/bin"; mkdir -p "$M"
cat > "$M/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }; exec /usr/bin/id "$@"
EOF
cat > "$M/hostname" <<'EOF'
#!/bin/sh
echo node1
EOF
cat > "$M/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$M/curl" <<'EOF'
#!/bin/bash
for a; do u=$a; done
case $u in
  */v2/*/tags/list) [ "${MOCK_REG_EMPTY:-0}" = 1 ] && { echo '{"tags":[]}'; exit 0; }
                    echo '{"name":"x","tags":["v3.6.0","v0.28.1","v1.9.1","12.3.1"]}';;
  *) exit 7;;
esac
EOF
# cephadm mock: argv -> $MOCK_DIR/argv.log, stdin -> $MOCK_DIR/stdin.<n>, fd0 target -> fd0.log
cat > "$M/cephadm" <<'EOF'
#!/bin/bash
d=$MOCK_DIR; n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo $n > "$d/n"
echo "$n $*" >> "$d/argv.log"; echo "$n $(readlink /proc/$$/fd/0)" >> "$d/fd0.log"
cat > "$d/stdin.$n"
c="$*"
case $c in
  *"config-key exists mgr/dashboard/crt"*) exit "${MOCK_CRT_EXISTS:-1}";;
  *"dashboard ac-user-show"*) exit "${MOCK_USER_EXISTS:-2}";;
  *"secure_monitoring_stack"*) echo false;;
  *"osd getcrushmap"*) printf 'BIN\001\002';;
  *"radosgw-admin"*) [ "${MOCK_NO_RGW:-0}" = 1 ] && { echo "no realm" >&2; exit 2; }; echo '{}';;
  *) echo "out:$c";;
esac
exit 0
EOF
chmod +x "$M"/*
runm() { # conf -> stdout+stderr; mock state in $W/m
  rm -rf "$W/m"; mkdir -p "$W/m"
  env PATH="$M:$PATH" MOCK_DIR="$W/m" CONF="$1" "${@:2}" bash "$SM" 2>&1
}
PWF="$W/secret/dash.pass"
mkconf "$W/a.conf" "DASHBOARD_ADMIN_PASSWORD_FILE=$PWF"
out=$(runm "$W/a.conf"); rc=$?
check "apply rc" 0 "$rc"
check "password file generated, mode 600" 600 "$(stat -c %a "$PWF" 2>/dev/null)"
PW=$(head -n1 "$PWF" 2>/dev/null)
check "password length 24" 24 "${#PW}"
hasnt "password never on stdout/stderr" "$PW" "$out"
hasnt "password never on cephadm argv" "$PW" "$(cat "$W/m/argv.log")"
cu=$(grep -n "ac-user-create admin -i - administrator --force-password" "$W/m/argv.log" | cut -d' ' -f1 | cut -d: -f2)
[ -n "$cu" ] && ok "ac-user-create via -i -" || nok "ac-user-create not called"
check "ac-user-create stdin = password" "$PW" "$(cat "$W/m/stdin.${cu:-x}" 2>/dev/null)"
ap=$(grep "orch apply -i -" "$W/m/argv.log" | cut -d' ' -f1)
has "orch apply stdin = spec" 'retention_time: "15d"' "$(cat "$W/m/stdin.${ap:-x}" 2>/dev/null)"
ci=$(grep -n "container_image_grafana" "$W/m/argv.log" | head -n1 | cut -d: -f1); ai=$(grep -n "orch apply" "$W/m/argv.log" | cut -d: -f1)
[ -n "$ci" ] && [ -n "$ai" ] && [ "$ci" -lt "$ai" ] && ok "image keys set before orch apply" || nok "image keys order"
has "self-signed cert created" "dashboard create-self-signed-cert" "$(cat "$W/m/argv.log")"
has "mgr prometheus module" "mgr module enable prometheus" "$(cat "$W/m/argv.log")"
has "sd port" "mgr/cephadm/service_discovery_port 8765" "$(cat "$W/m/argv.log")"
# every non -i call must have stdin closed (/dev/null)
nonnull=$(join <(grep -v -- ' -i -' "$W/m/argv.log" | cut -d' ' -f1 | sort) <(sort "$W/m/fd0.log") | awk '$2!="/dev/null"' | wc -l)
check "ceph_ calls run with stdin=/dev/null" 0 "$nonnull"
# second run: user exists, cert exists, password file kept
out=$(runm "$W/a.conf" MOCK_USER_EXISTS=0 MOCK_CRT_EXISTS=0)
check "password file unchanged on re-run" "$PW" "$(head -n1 "$PWF")"
hasnt "existing user: no create" "ac-user-create" "$(cat "$W/m/argv.log")"
hasnt "existing user: no set-password" "ac-user-set-password" "$(cat "$W/m/argv.log")"
hasnt "stored cert kept" "create-self-signed-cert" "$(cat "$W/m/argv.log")"
out=$(runm "$W/a.conf" MOCK_USER_EXISTS=0 DASHBOARD_RESET_PASSWORD=1)
has "DASHBOARD_RESET_PASSWORD=1 sets password via stdin" "ac-user-set-password admin -i - --force-password" "$(cat "$W/m/argv.log")"
hasnt "reset: password not printed" "$PW" "$out"
# custom cert + grafana admin password
printf 'CERTDATA\n' > "$W/d.crt"; printf 'KEYDATA\n' > "$W/d.key"; printf "g'pw\n" > "$W/g.pass"
mkconf "$W/b.conf" "DASHBOARD_ADMIN_PASSWORD_FILE=$PWF" "DASHBOARD_CERT=$W/d.crt" "DASHBOARD_KEY=$W/d.key" "GRAFANA_ADMIN_PASSWORD_FILE=$W/g.pass"
out=$(runm "$W/b.conf")
sc=$(grep "set-ssl-certificate -i -" "$W/m/argv.log" | cut -d' ' -f1); sk=$(grep "set-ssl-certificate-key -i -" "$W/m/argv.log" | cut -d' ' -f1)
check "cert via stdin" CERTDATA "$(cat "$W/m/stdin.${sc:-x}" 2>/dev/null)"
check "key via stdin" KEYDATA "$(cat "$W/m/stdin.${sk:-x}" 2>/dev/null)"
hasnt "custom cert: no self-signed" "create-self-signed-cert" "$(cat "$W/m/argv.log")"
ap=$(grep "orch apply -i -" "$W/m/argv.log" | cut -d' ' -f1)
has "grafana initial_admin_password yaml-quoted in spec stdin" "initial_admin_password: 'g''pw'" "$(cat "$W/m/stdin.${ap:-x}" 2>/dev/null)"
hasnt "grafana password not on argv" "g'pw" "$(cat "$W/m/argv.log")"
hasnt "grafana password not printed" "g'pw" "$out"
out=$(runm "$W/a.conf" MOCK_REG_EMPTY=1); rc=$?
check "registry without monitoring images -> fail" 1 "$rc"; has "registry error message" "has no prometheus/prometheus:v3.6.0" "$out"
hasnt "registry missing: nothing applied" "orch apply" "$(cat "$W/m/argv.log" 2>/dev/null)"

# ---- 4. deploy.sh / verify.sh wiring ---------------------------------------------------------
out=$(CONF="$W/def.conf" bash "$O/deploy.sh" --dry-run 2>&1)
has "deploy stage order" "stages: validate install bootstrap hosts osd-preview osd pools rgw cephfs vip monitoring verify" "$out"
has "deploy runs setup-monitoring" "mgr/cephadm/container_image_prometheus" "$out"
out=$(CONF="$W/def.conf" bash "$O/deploy.sh" --dry-run --only monitoring 2>&1); rc=$?
check "--only monitoring rc" 0 "$rc"; has "--only monitoring selects one stage" "stages: monitoring" "$out"
has "--only monitoring skip when off" "ENABLE_MONITORING=0 ENABLE_DASHBOARD=0, skip" "$(CONF="$W/off.conf" bash "$O/deploy.sh" --dry-run --only monitoring 2>&1)"
hasnt "backup never in deploy" "backup" "$(cat "$O/deploy.sh")"
out=$(CONF="$W/def.conf" bash "$O/verify.sh" --dry-run 2>&1)
has "verify dry-run exporter" ":9926/metrics" "$out"; has "verify dry-run sd" ":8765/sd/prometheus/sd-config" "$out"; has "verify dry-run dashboard" "dashboard URL (https :8443)" "$out"
grep -q -- '--skip-monitoring-stack' "$O/bootstrap.sh" && grep -q 'container_image_node_exporter' "$O/bootstrap.sh" \
  && ok "bootstrap: monitoring moved to stage + image keys pinned" || nok "bootstrap image keys"

# ---- 5. download-debs.sh pin -------------------------------------------------------------------
if [ -n "$B" ]; then
  D=$(cat "$B/download-debs.sh")
  has "ceph repo debian-<ver> noble" 'https://download.ceph.com/debian-${CEPH_VERSION}}' "$D"
  has "repo line noble main" '${CEPH_REPO} noble main' "$D"
  has "pin priority 1001" "Pin-Priority: 1001" "$D"
  for p in ceph-common librados2 librbd1 'python3-ceph\*'; do grep -q "^Package: .*${p}" "$B/download-debs.sh" && ok "pinned $p" || nok "not pinned $p"; done
  has "pin version 20.2.4-1noble default" 'CEPH_DEB_VERSION:-${CEPH_VERSION}-1noble' "$D"
  grep -qx librados2 "$B/packages.list" && grep -qx librbd1 "$B/packages.list" && ok "packages.list lists librados2/librbd1" || nok "packages.list"
fi

# ---- 6. backup-cluster-meta.sh ------------------------------------------------------------------
BK="$O/backup-cluster-meta.sh"
out=$(CONF="$W/def.conf" bash "$BK" --dry-run --out /srv/bk 2>&1)
has "backup dry-run out dir" "/srv/bk/ceph-meta-<fsid>-" "$out"
for it in "auth ls" "config dump" "config-key dump" "orch ls --export" "osd getcrushmap" "mon dump" "fs dump" "radosgw-admin zone get" "radosgw-admin realm list"; do has "backup item: $it" "$it" "$out"; done
cmds=$(sed -n '/^ITEMS=(/,/^)/p' "$BK")
if grep -Eq ' (set|rm|del|create|apply|enable|disable|zap|import|remove|purge|reweight|out|in)( |")' <<<"$cmds"; then nok "backup items contain a mutating verb"; else ok "backup items are read-only"; fi
hasnt "backup: no cron/timer" "crontab" "$(cat "$BK")"; hasnt "backup: no systemctl" "systemctl" "$(cat "$BK")"
mkdir -p "$W/etc-ceph"; printf '[global]\n\tfsid = abcd-1234\n' > "$W/etc-ceph/ceph.conf"; printf 'key\n' > "$W/etc-ceph/ceph.client.admin.keyring"
rm -rf "$W/m"; mkdir -p "$W/m"
out=$(env PATH="$M:$PATH" MOCK_DIR="$W/m" CONF="$W/def.conf" CEPH_ETC="$W/etc-ceph" MOCK_NO_RGW=1 bash "$BK" --out "$W/bk" 2>&1); rc=$?
check "backup rc (rgw absent is not an error)" 0 "$rc"
tf=$(ls "$W"/bk/ceph-meta-abcd-1234-*.tar.gz 2>/dev/null | head -n1)
[ -n "$tf" ] && ok "backup tar named ceph-meta-<fsid>-<date>.tar.gz" || nok "backup tar missing"
check "backup tar mode 600" 600 "$(stat -c %a "$tf" 2>/dev/null)"
check "backup dir mode 700" 700 "$(stat -c %a "$W/bk")"
lst=$(tar -tzf "$tf" 2>/dev/null)
for f in etc-ceph/ceph.client.admin.keyring auth-ls.txt config-key-dump.json orch-ls-export.yaml crushmap.bin mon-dump.txt fs-dump.txt MANIFEST.txt SHA256SUMS; do has "tar has $f" "$f" "$lst"; done
check "no leftover work dir" "" "$(find "$W/bk" -mindepth 1 -maxdepth 1 -name '.*')"
check "backup cephadm calls stdin=/dev/null" 0 "$(awk '$2!="/dev/null"' "$W/m/fd0.log" | wc -l)"
nm=$(grep -c . "$W/m/argv.log"); hasnt "backup: no write verbs on argv" " set " "$(cat "$W/m/argv.log")"
check "backup ran all items" 18 "$nm"

echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
