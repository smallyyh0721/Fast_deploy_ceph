#!/usr/bin/env bash
# Unit tests for the optional S3 BGP entry (no root, no FRR, no network):
#   HAProxy CSV parsing, rise/fall, evaluate (+ stats auth never on argv), probe modes,
#   refuse-overwrite (frr.conf / dummy), config checks, setup/teardown/deploy dry-run.
# Run: ./tests/test-s3-bgp.sh
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd); O=$(cd "$T/.." && pwd); F="$T/fixtures/s3-bgp"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
nok() { fail=$((fail+1)); echo "FAIL $*"; }
check() { local name=$1 want=$2 got=$3; if [ "$got" = "$want" ]; then ok "$name"; else nok "$name: got '$got' want '$want'"; fi; }
has() { local name=$1 needle=$2 hay=$3; if [[ $hay == *"$needle"* ]]; then ok "$name"; else nok "$name: missing '$needle'"; fi; }
hasnt() { local name=$1 needle=$2 hay=$3; if [[ $hay != *"$needle"* ]]; then ok "$name"; else nok "$name: unexpected '$needle'"; fi; }

# ---- 1. HAProxy stats CSV parsing ----------------------------------------------------
H="$O/s3-bgp/health.sh"
check "csv healthy (1 of 2 rgw UP, BACKEND row ignored)" "frontend=OPEN backend_up=1" "$("$H" parse-stats "$F/stats-healthy.csv")"
check "csv all rgw down/maint" "frontend=OPEN backend_up=0" "$("$H" parse-stats "$F/stats-backend-down.csv")"
check "csv frontend STOP" "frontend=STOP backend_up=1" "$("$H" parse-stats "$F/stats-frontend-stop.csv")"
check "csv 'UP 1/3' counts, non-rgw server ignored" "frontend=OPEN backend_up=1" "$("$H" parse-stats "$F/stats-transitional.csv")"
check "csv default names on custom cfg -> frontend missing" "frontend=MISSING backend_up=0" "$("$H" parse-stats "$F/stats-custom-names.csv")"
check "csv custom names via env" "frontend=OPEN backend_up=1" \
  "$(S3_BGP_FRONTEND_NAME=fe_s3 S3_BGP_BACKEND_NAME=be_s3 S3_BGP_BACKEND_SERVER_PREFIX=radosgw. "$H" parse-stats "$F/stats-custom-names.csv")"
check "csv garbage (HTML/no header)" "frontend=NOHEADER backend_up=0" "$("$H" parse-stats "$F/stats-garbage.csv")"

# ---- 2. rise/fall state machine ------------------------------------------------------
# shellcheck disable=SC2030
seq_out=$(
  # shellcheck source=../s3-bgp/health.sh
  . "$H"; S3_BGP_RISE=3; S3_BGP_FALL=2; r=""
  for g in 1 1 1 1 0 1 0 0 0 1 1 1; do step "$g"; r+="${ACTION:0:1}"; done; echo "$r")
check "rise 3 / fall 2 sequence" "kkakkkkwkkka" "$seq_out"

# ---- 3. evaluate(): stats auth via stdin only, probes, maintenance flag --------------
mkdir -p "$W/bin"; cp "$F/fake-curl" "$W/bin/curl"
cat > "$W/node.conf" <<EOC
S3_BGP_VIP=10.0.0.50
S3_BGP_LOCAL_ASN=65050
S3_BGP_HAPROXY_CFG=""
S3_BGP_HAPROXY_GLOB="$W/ceph/*/haproxy.rgw.main.*/haproxy/haproxy.cfg"
S3_BGP_STATS_URL="http://10.0.0.42:1968/stats;csv"
S3_BGP_FRONTEND_NAME=frontend; S3_BGP_BACKEND_NAME=backend; S3_BGP_BACKEND_SERVER_PREFIX=rgw.
S3_BGP_PROBE_MODE=anon-xml; S3_BGP_PROBE_URL="http://10.0.0.42:8080/"
S3_BGP_PROBE_EXPECT=ListAllMyBucketsResult; S3_BGP_PROBE_CODES="200 403"
EOC
mkdir -p "$W/ceph/fsid1/haproxy.rgw.main.node2.old/haproxy" "$W/ceph/fsid1/haproxy.rgw.main.node2.new/haproxy"
cp "$F/haproxy.cfg" "$W/ceph/fsid1/haproxy.rgw.main.node2.old/haproxy/"; sleep 1
cp "$F/haproxy.cfg" "$W/ceph/fsid1/haproxy.rgw.main.node2.new/haproxy/"
ev() { env PATH="$W/bin:$PATH" FAKE_LOG="$W/curl.log" S3_BGP_NODE_CONF="$W/node.conf" \
       S3_BGP_DISABLE_FLAG="$W/disabled" "$@" "$H" check 2>&1; }
XML='<?xml version="1.0"?><ListAllMyBucketsResult><Owner/></ListAllMyBucketsResult>'
out=$(ev env FAKE_STATS="$F/stats-healthy.csv" FAKE_BODY="$XML" FAKE_CODE=200); rc=$?
check "evaluate healthy rc" 0 "$rc"; has "evaluate healthy text" "HEALTHY: frontend=OPEN backend_up=1, probe ok" "$out"
hasnt "stats password never on curl argv" "FAKE-SECRET-123" "$(cat "$W/curl.log")"
has "stats auth passed on curl stdin (-K -)" 'user = "admin:FAKE-SECRET-123"' "$(cat "$W/curl.log.stdin")"
has "haproxy.cfg discovered at runtime (newest of glob)" "node2.new" \
  "$(S3_BGP_HAPROXY_GLOB="$W/ceph/*/haproxy.rgw.main.*/haproxy/haproxy.cfg" bash -c ". '$H'; discover_haproxy_cfg")"
out=$(ev env FAKE_STATS="$F/stats-backend-down.csv" FAKE_BODY="$XML"); check "evaluate backend down rc" 1 "$?"
out=$(ev env FAKE_STATS="$F/stats-frontend-stop.csv" FAKE_BODY="$XML"); check "evaluate frontend stop rc" 1 "$?"
out=$(ev env FAKE_STATS="" FAKE_BODY="$XML"); rc=$?; check "evaluate stats unreachable rc" 1 "$rc"; has "stats unreachable text" "stats unreachable" "$out"
out=$(ev env FAKE_STATS="$F/stats-healthy.csv" FAKE_BODY='<Error><Code>AccessDenied</Code></Error>' FAKE_CODE=403); rc=$?
check "anon-xml: 403 AccessDenied is unhealthy" 1 "$rc"
out=$(ev env FAKE_STATS="$F/stats-healthy.csv" FAKE_BODY='<Error/>' FAKE_CODE=403 S3_BGP_PROBE_MODE=http-status); rc=$?
# PROBE_MODE comes from node.conf (sourced after env) -> override by a second conf
sed 's/^S3_BGP_PROBE_MODE=anon-xml/S3_BGP_PROBE_MODE=http-status/' "$W/node.conf" > "$W/node-http.conf"
out=$(env PATH="$W/bin:$PATH" FAKE_LOG="$W/curl.log" S3_BGP_NODE_CONF="$W/node-http.conf" S3_BGP_DISABLE_FLAG="$W/disabled" \
      FAKE_STATS="$F/stats-healthy.csv" FAKE_CODE=403 "$H" check 2>&1); check "http-status: 403 accepted (codes 200 403)" 0 "$?"
out=$(env PATH="$W/bin:$PATH" FAKE_LOG="$W/curl.log" S3_BGP_NODE_CONF="$W/node-http.conf" S3_BGP_DISABLE_FLAG="$W/disabled" \
      FAKE_STATS="$F/stats-healthy.csv" FAKE_CODE=503 "$H" check 2>&1); check "http-status: 503 rejected" 1 "$?"
touch "$W/disabled"
out=$(ev env FAKE_STATS="$F/stats-healthy.csv" FAKE_BODY="$XML"); rc=$?
check "maintenance flag forces unhealthy" 1 "$rc"; has "maintenance text" "maintenance flag" "$out"; rm -f "$W/disabled"
sed "s|^S3_BGP_HAPROXY_GLOB=.*|S3_BGP_HAPROXY_GLOB=\"$W/none/*.cfg\"|" "$W/node.conf" > "$W/node-nocfg.conf"
out=$(env PATH="$W/bin:$PATH" FAKE_LOG="$W/curl.log" S3_BGP_NODE_CONF="$W/node-nocfg.conf" FAKE_STATS="$F/stats-healthy.csv" "$H" check 2>&1)
check "no haproxy.cfg -> unhealthy" 1 "$?"
unset S3_BGP_HAPROXY_GLOB_SAVE

# ---- 4. vtysh withdraw tolerance (FRR 8.4 rc=1 "Can't find static route") ------------
cat > "$W/bin/vtysh" <<'EOV'
#!/bin/bash
echo "$*" >> "$FAKE_VTYSH_LOG"
if [[ "$*" == *"no network"* ]]; then echo "% Can't find static route specified"; exit 1; fi
EOV
chmod +x "$W/bin/vtysh"
out=$(env PATH="$W/bin:$PATH" FAKE_VTYSH_LOG="$W/vtysh.log" S3_BGP_NODE_CONF="$W/node.conf" "$H" withdraw 2>&1)
check "withdraw of absent network is OK" 0 "$?"
has "withdraw command shape" "-c configure terminal -c router bgp 65050 -c address-family ipv4 unicast -c no network 10.0.0.50/32" "$(cat "$W/vtysh.log")"

# ---- 5. refuse-overwrite: frr.conf ownership + dummy ownership -----------------------
# shellcheck source=../s3-bgp/common.sh
. "$O/s3-bgp/common.sh"
check "frr.conf absent" absent "$(s3b_frr_conf_status "$W/nope.conf" x)"
check "frr.conf foreign -> refuse" foreign "$(s3b_frr_conf_status "$F/frr-foreign.conf" 0123)"
check "frr.conf package default (dpkg md5 match)" pkg-default \
  "$(s3b_frr_conf_status "$F/frr-pkg-default.conf" "$(md5sum < "$F/frr-pkg-default.conf" | cut -d' ' -f1)")"
check "frr.conf edited package default -> refuse" foreign "$(s3b_frr_conf_status "$F/frr-pkg-default.conf" deadbeef)"
printf '! %s\nrouter bgp 1\n' "$S3B_MARKER" > "$W/ours.conf"
check "frr.conf ours -> overwrite allowed" ours "$(s3b_frr_conf_status "$W/ours.conf" x)"
cat > "$W/bin/ip" <<'EOI'
#!/bin/bash
case "$FAKE_IP" in
  absent) exit 1;;
  ours) [[ "$*" == *"-4 addr"* ]] && { echo "9: s3vip0    inet 10.0.0.50/32 scope global s3vip0"; exit 0; }
        echo '9: s3vip0: <BROADCAST,NOARP,UP> mtu 1500 qdisc noqueue \    link/ether aa:bb brd ff:ff \    alias fast-deploy-s3-bgp \    dummy addrgenmode eui64'; exit 0;;
  notdummy) echo '2: s3vip0: <UP> mtu 1500 \    link/ether aa:bb \    vlan protocol 802.1Q id 5'; exit 0;;
  noalias) echo '9: s3vip0: <UP> mtu 1500 \    link/ether aa:bb \    dummy addrgenmode eui64'; exit 0;;
  extraaddr) [[ "$*" == *"-4 addr"* ]] && { echo "9: s3vip0    inet 192.168.9.9/24 scope global s3vip0"; exit 0; }
        echo '9: s3vip0: <UP> \    alias fast-deploy-s3-bgp \    dummy addrgenmode eui64'; exit 0;;
esac
EOI
chmod +x "$W/bin/ip"
ds() { env FAKE_IP="$1" IP_CMD="$W/bin/ip" S3_BGP_VIP=10.0.0.50 bash -c ". '$O/s3-bgp/network.sh'; dummy_state s3vip0"; }
check "dummy absent" absent "$(ds absent)"
check "dummy ours" ours "$(ds ours)"
has "dummy not a dummy -> foreign" "foreign:not a dummy" "$(ds notdummy)"
has "dummy without our alias -> foreign" "foreign:alias" "$(ds noalias)"
has "dummy with extra address -> foreign" "foreign:unexpected address" "$(ds extraaddr)"

# ---- 6. setup --local refuses a foreign frr.conf before changing anything ------------
mkdir -p "$W/etcfrr" "$W/state"; cp "$F/frr-foreign.conf" "$W/etcfrr/frr.conf"; cp "$W/etcfrr/frr.conf" "$W/frr.before"
cat > "$W/local.conf" <<EOC
S3_BGP_HOSTNAME=node2; S3_BGP_LOCAL_IP=127.0.0.1; S3_BGP_ROUTER_ID=127.0.0.1; S3_BGP_VIP=10.0.0.50
S3_BGP_LOCAL_ASN=65050; S3_BGP_PEER_IP=10.0.0.1; S3_BGP_PEER_ASN=65000; S3_BGP_IFACE=""; S3_BGP_DUMMY=fdtest$$
S3_BGP_KEEPALIVE=3; S3_BGP_HOLD=9; S3_BGP_PREFIX_LIST=S3VIP; S3_BGP_HAPROXY_CFG="$F/haproxy.cfg"; S3_BGP_HAPROXY_GLOB=""
BUNDLE_DIR=$W/nobundle
EOC
out=$(env S3B_FRR_DIR="$W/etcfrr" S3B_STATE="$W/state" S3B_ETCDIR="$W/etc" S3B_LIBDIR="$W/lib" S3B_UNITDIR="$W/units" \
      bash "$O/setup-s3-bgp.sh" --local "$W/local.conf" 2>&1); rc=$?
check "setup --local foreign frr.conf rc" 1 "$rc"; has "setup --local refuse message" "refuse: $W/etcfrr/frr.conf exists" "$out"
if cmp -s "$W/frr.before" "$W/etcfrr/frr.conf" && [ -z "$(ls -A "$W/state")" ] && [ ! -e "$W/etc" ] && [ ! -e "$W/units" ]; then
  ok "refused run changed nothing"; else nok "refused run changed files"; fi
# dummy name collision with an existing non-dummy iface (fake ip for the dummy probe only)
sed -i "s/S3_BGP_DUMMY=fdtest$$/S3_BGP_DUMMY=s3vip0/; s/S3_BGP_IFACE=\"\"/S3_BGP_IFACE=lo/" "$W/local.conf"; rm -f "$W/etcfrr/frr.conf"
out=$(env FAKE_IP=notdummy IP_CMD="$W/bin/ip" S3B_FRR_DIR="$W/etcfrr" S3B_STATE="$W/state" \
      bash "$O/setup-s3-bgp.sh" --local "$W/local.conf" 2>&1); rc=$?
check "setup --local existing foreign iface rc" 1 "$rc"; has "foreign iface refuse message" "refuse: interface s3vip0 exists and is not ours" "$out"

# ---- 7. config checks + dry-runs (cluster.conf.example based) ------------------------
mk_conf() {  # $1 out; rest: sed expressions
  local o=$1; shift; cp "$O/cluster.conf.example" "$o"; local e; for e in "$@"; do sed -i "$e" "$o"; done; }
BASE=('s/^ENABLE_RGW=0/ENABLE_RGW=1/' 's/^RGW_INGRESS=0/RGW_INGRESS=1/' 's/^RGW_VIP=""/RGW_VIP="10.250.0.20"/')
mk_conf "$W/off.conf" "${BASE[@]}"
mk_conf "$W/on.conf" "${BASE[@]}" 's/^ENABLE_S3_BGP=0/ENABLE_S3_BGP=1/' 's/^S3_BGP_PEER_IP=""/S3_BGP_PEER_IP="10.250.0.1"/' \
  's/^S3_BGP_ROUTER_IDS=()/S3_BGP_ROUTER_IDS=("node3=10.250.0.99")/'
mk_conf "$W/bad.conf" "${BASE[@]}" 's/^ENABLE_S3_BGP=0/ENABLE_S3_BGP=1/' 's/^S3_BGP_PEER_IP=""/S3_BGP_PEER_IP="10.250.0.300"/' \
  's/^S3_BGP_PEER_ASN=65000/S3_BGP_PEER_ASN=65050/' 's/^S3_BGP_DUMMY="s3vip0"/S3_BGP_DUMMY="this-name-is-too-long"/'
out=$(CONF="$W/off.conf" bash "$O/setup-s3-bgp.sh" --dry-run 2>&1); rc=$?
check "setup with ENABLE_S3_BGP=0 refuses" 1 "$rc"; has "ENABLE_S3_BGP=0 message" "ENABLE_S3_BGP=0" "$out"
out=$(CONF="$W/bad.conf" bash "$O/setup-s3-bgp.sh" --check-conf 2>&1); rc=$?
check "bad config rejected" 1 "$rc"
has "bad peer ip reported" "S3_BGP_PEER_IP '10.250.0.300'" "$out"
has "iBGP reported" "ASN equal" "$out"
has "bad dummy reported" "S3_BGP_DUMMY" "$out"
out=$(CONF="$W/on.conf" bash "$O/setup-s3-bgp.sh" --dry-run 2>&1); rc=$?
check "setup --dry-run rc" 0 "$rc"
has "dry-run both RGW hosts" "---- node3" "$out"
has "dry-run prefix-list OUT only VIP/32" "ip prefix-list S3VIP-OUT seq 10 permit 10.250.0.20/32" "$out"
has "dry-run prefix-list IN deny all" "ip prefix-list S3VIP-IN seq 10 deny 0.0.0.0/0 le 32" "$out"
has "dry-run router-id default = node IP" "bgp router-id 10.250.0.12" "$out"
has "dry-run router-id override" "bgp router-id 10.250.0.99" "$out"
has "dry-run timers" "neighbor 10.250.0.1 timers 3 9" "$out"
has "dry-run ebgp-requires-policy" "bgp ebgp-requires-policy" "$out"
frr_body=$(sed -n '/write \/etc\/frr\/frr.conf:/,/write \/etc\/sysctl.d/p' <<<"$out")
if grep -Eq '^ +network ' <<<"$frr_body"; then nok "frr.conf must not contain a network statement"; else ok "frr.conf has no hardcoded network VIP"; fi
has "dry-run sysctl only on business iface" "net.ipv4.conf.<iface-holding-node-ip>.arp_ignore=1" "$out"
out=$(CONF="$W/on.conf" bash "$O/teardown-s3-bgp.sh" --dry-run 2>&1); rc=$?
check "teardown --dry-run rc" 0 "$rc"; has "teardown restores ARP" "restore arp_ignore/arp_announce" "$out"
# deploy.sh: optional stage only via --only
out=$(CONF="$W/on.conf" bash "$O/deploy.sh" --dry-run --only s3-bgp 2>&1); rc=$?
check "deploy --only s3-bgp dry-run rc" 0 "$rc"; has "deploy --only s3-bgp renders" "permit 10.250.0.20/32" "$out"
out=$(CONF="$W/on.conf" bash "$O/deploy.sh" --dry-run 2>&1)
has "default run stage list unchanged" "stages: validate install bootstrap hosts osd-preview osd pools rgw cephfs vip verify" "$out"
hasnt "default run never configures BGP" "prefix-list" "$out"
out=$(CONF="$W/on.conf" bash "$O/deploy.sh" --dry-run --from s3-bgp 2>&1); check "--from s3-bgp rejected" 1 "$?"
out=$(CONF="$W/off.conf" bash "$O/deploy.sh" --dry-run --only s3-bgp 2>&1); check "--only s3-bgp with ENABLE_S3_BGP=0 fails" 1 "$?"
# systemd units: frr.service is Before=network.target, so the drop-in must not order it after
# s3-bgp-network (After=network-online.target) -> boot-time ordering cycle (found in container test)
dropin=$(grep -v '^#' "$O/s3-bgp/templates/frr-s3-bgp.conf.in")
hasnt "frr drop-in has no After= (no boot cycle)" "After=" "$dropin"
hasnt "frr drop-in has no Requires= (no boot cycle)" "Requires=" "$dropin"
# verify.sh jq: FRR 8.4 'show bgp ipv4 unicast summary json' has .peers at top level; plain
# 'show bgp summary json' wraps it in .ipv4Unicast. Both must parse.
if command -v jq >/dev/null; then
  jqx=$(grep -o "jq -r '(.ipv4Unicast // .).peers\[[^|]*| [^']*'" "$O/verify.sh" | head -1)
  has "verify.sh jq accepts both JSON shapes" "(.ipv4Unicast // .)" "$jqx"
  q='(.ipv4Unicast // .).peers["10.0.0.1"] | "peer=\(.state) pfxRcd=\(.pfxRcd // 0)"'
  check "jq flat shape" "peer=Established pfxRcd=0" "$(jq -r "$q" <<<'{"peers":{"10.0.0.1":{"state":"Established","pfxRcd":0}}}')"
  check "jq wrapped shape" "peer=Active pfxRcd=0" "$(jq -r "$q" <<<'{"ipv4Unicast":{"peers":{"10.0.0.1":{"state":"Active"}}}}')"
fi
echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
