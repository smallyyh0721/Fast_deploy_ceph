#!/usr/bin/env bash
# Run as root on EVERY node (node1 first). Idempotent; safe to re-run.
#   sudo ./install-node.sh            # verify bundle, install debs, chrony, cephadm, images
#   sudo ./install-node.sh --skip-verify
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root; load_conf

SKIP_VERIFY=0
for a in "$@"; do case $a in --skip-verify) SKIP_VERIFY=1;; *) die "unknown arg $a";; esac; done

IDX=$(self_index)
[ "$IDX" -ge 0 ] || die "hostname -s '$(hostname -s)' not in NODE_NAMES (${NODE_NAMES[*]})"
MY_IP=${NODE_IPS[$IDX]}
ROLE="member"; [ "$IDX" -eq 0 ] && ROLE="admin"
log "node $(hostname -s) ip $MY_IP role $ROLE"

# --- preflight ---------------------------------------------------------------
. /etc/os-release
[ "${VERSION_ID:-}" = "24.04" ] || warn "expected Ubuntu 24.04, got ${PRETTY_NAME:-?}"
[ "$(uname -m)" = x86_64 ] || die "bundle is x86_64/amd64, host is $(uname -m)"
ip -o addr | grep -qw "$MY_IP" || die "IP $MY_IP not configured on this host"
[ -d "$BUNDLE_DIR/debs" ] || die "$BUNDLE_DIR/debs missing (extract bundle to $BUNDLE_DIR)"

# --- 1. verify bundle ---------------------------------------------------------
if [ "$SKIP_VERIFY" -eq 0 ]; then
  log "verifying SHA256SUMS (takes a minute)"
  ( cd "$BUNDLE_DIR" && sha256sum --quiet -c SHA256SUMS ) || die "checksum mismatch"
fi

# --- 2. local apt repo + packages ----------------------------------------------
LIST=/etc/apt/sources.list.d/ceph-offline.list
echo "deb [trusted=yes] file://$BUNDLE_DIR/debs ./" > "$LIST"
log "apt update (offline repo only)"
apt-get update -q -o Dir::Etc::sourcelist="$LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 >/dev/null
# apt's file: method + --no-download fails ("Pathname to install is not absolute"),
# so stage the debs in apt's archive cache; --no-download then uses them and never fetches.
cp -n "$BUNDLE_DIR"/debs/*.deb /var/cache/apt/archives/ 2>/dev/null || true
mapfile -t PKGS < <(grep -Ev '^\s*(#|$)' "$HERE/packages.list")
log "apt install --no-download: ${PKGS[*]}"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-download --no-install-recommends \
  -o Dir::Etc::sourcelist="$LIST" -o Dir::Etc::sourceparts=- "${PKGS[@]}"

# --- 3. ssh + time --------------------------------------------------------------
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now ssh.socket
CHRONY=/etc/chrony/conf.d/ceph-offline.conf
mkdir -p /etc/chrony/conf.d /etc/chrony/sources.d
# disable default internet pools (unreachable anyway)
sed -i 's/^\(pool .*\)$/# offline: \1/' /etc/chrony/chrony.conf
if [ "$ROLE" = admin ]; then
  {
    echo "# managed by Fast_deploy_ceph: node1 is the cluster time source"
    [ -n "$UPSTREAM_NTP" ] && echo "server $UPSTREAM_NTP iburst"
    echo "local stratum 10"
    echo "allow $NTP_ALLOW"
  } > "$CHRONY"
else
  printf '# managed by Fast_deploy_ceph\nserver %s iburst\n' "$ADMIN_IP" > "$CHRONY"
fi
systemctl enable chrony >/dev/null 2>&1; systemctl restart chrony

# --- 4. cephadm ---------------------------------------------------------------
install -m 0755 "$BUNDLE_DIR/bin/cephadm" /usr/local/sbin/cephadm
cephadm version

# --- 5. registry trust (all nodes) ------------------------------------------------
mkdir -p /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/99-ceph-local.conf <<EOR
[[registry]]
location = "$REGISTRY"
insecure = true
EOR

has_image() { podman image exists "$1"; }
load_ceph_image() {
  if ! has_image "$CEPH_IMAGE_SRC"; then
    log "podman load ceph image"
    podman load -i "$BUNDLE_DIR/images/ceph-v${CEPH_VERSION}.tar"
  fi
  podman tag "$CEPH_IMAGE_SRC" "$CEPH_IMAGE"
}

# --- 6. registry on admin node -------------------------------------------------------
if [ "$ROLE" = admin ]; then
  has_image docker.io/library/registry:2 || podman load -i "$BUNDLE_DIR/images/registry-2.tar"
  load_ceph_image
  mkdir -p /var/lib/ceph-local-registry
  cat > /etc/systemd/system/ceph-local-registry.service <<EOU
[Unit]
Description=Local container registry for air-gapped Ceph ($REGISTRY)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=/usr/bin/podman run --rm --replace --name ceph-local-registry -p ${ADMIN_IP}:${REGISTRY_PORT}:5000 -v /var/lib/ceph-local-registry:/var/lib/registry docker.io/library/registry:2
ExecStop=/usr/bin/podman stop -t 10 ceph-local-registry
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOU
  systemctl daemon-reload
  systemctl enable ceph-local-registry.service >/dev/null 2>&1
  systemctl restart ceph-local-registry.service
  for _ in $(seq 1 30); do curl -fsS "http://$REGISTRY/v2/" >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS "http://$REGISTRY/v2/" >/dev/null || die "registry not answering on $REGISTRY"
  if ! curl -fsS "http://$REGISTRY/v2/ceph/ceph/tags/list" 2>/dev/null | grep -q "v${CEPH_VERSION}"; then
    log "push $CEPH_IMAGE"
    podman push --tls-verify=false "$CEPH_IMAGE"
  fi
  curl -fsS "http://$REGISTRY/v2/ceph/ceph/tags/list"; echo
else
  if [ "$LOAD_IMAGE_ON_ALL_NODES" = 1 ]; then load_ceph_image; fi
  if curl -fsS "http://$REGISTRY/v2/ceph/ceph/tags/list" 2>/dev/null | grep -q "v${CEPH_VERSION}"; then
    podman pull --tls-verify=false -q "$CEPH_IMAGE" >/dev/null && log "registry $REGISTRY reachable, pull OK"
  else
    warn "registry $REGISTRY not reachable yet (run install-node.sh on $ADMIN_NAME first); local image fallback: $LOAD_IMAGE_ON_ALL_NODES"
  fi
fi

# --- 7. summary --------------------------------------------------------------------
log "check-host"
cephadm check-host || die "cephadm check-host failed"
podman --version; chronyc -n sources 2>/dev/null | tail -n +1 || true
log "install-node.sh done on $(hostname -s)"
