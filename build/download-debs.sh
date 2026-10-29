#!/usr/bin/env bash
# Runs INSIDE a clean ubuntu:24.04 container (see build-bundle.sh).
# Downloads the full recursive dependency closure of packages.list so the
# local repo works on any clean Ubuntu 24.04 (server/cloud/minimal).
set -euo pipefail
OUT=${1:-/out}
LIST=${2:-/build/packages.list}
export DEBIAN_FRONTEND=noninteractive
# optional extra lists (e.g. packages-s3-bgp.list next to packages.list) join the same closure
EXTRA_LISTS=("${@:3}")
if [ "${#EXTRA_LISTS[@]}" -eq 0 ] && [ -f "$(dirname "$LIST")/packages-s3-bgp.list" ]; then
  EXTRA_LISTS=("$(dirname "$LIST")/packages-s3-bgp.list")
fi
mapfile -t PKGS < <(grep -hEv '^\s*(#|$)' "$LIST" "${EXTRA_LISTS[@]}")
# Host Ceph client packages = cluster version: upstream repo download.ceph.com/debian-<ver> (noble),
# pinned so Ubuntu's own ceph-common (19.2.x) can never win.
CEPH_VERSION=${CEPH_VERSION:-20.2.4}
CEPH_DEB_VERSION=${CEPH_DEB_VERSION:-${CEPH_VERSION}-1noble}
CEPH_REPO=${CEPH_REPO:-https://download.ceph.com/debian-${CEPH_VERSION}}
apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates curl >/dev/null
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.ceph.com/keys/release.asc -o /etc/apt/keyrings/ceph.asc
echo "deb [signed-by=/etc/apt/keyrings/ceph.asc] ${CEPH_REPO} noble main" > /etc/apt/sources.list.d/ceph.list
cat > /etc/apt/preferences.d/ceph-pin <<PIN
Package: ceph-common ceph-fuse ceph-base librados2 librbd1 libcephfs2 libcephfs-proxy2 libradosstriper1 librgw2 libsqlite3-mod-ceph python3-ceph* python3-rados python3-rbd python3-cephfs python3-rgw radosgw rbd-nbd
Pin: version ${CEPH_DEB_VERSION}
Pin-Priority: 1001
PIN
apt-get update -q
apt-get install -y -q --no-install-recommends apt-rdepends dpkg-dev >/dev/null
mkdir -p "$OUT"
cd "$OUT"
# 1) closure of Depends/PreDepends (real package names only)
apt-rdepends "${PKGS[@]}" 2>/dev/null | awk '/^[^[:space:]]/ {print $1}' | sort -u > /tmp/names.txt
: > unresolved-packages.txt
while read -r p; do
  if apt-cache show "$p" >/dev/null 2>&1 && apt-cache policy "$p" | awk '/Candidate:/ {print $2}' | grep -qv none; then
    echo "$p"
  else
    echo "$p" >> unresolved-packages.txt
  fi
done < /tmp/names.txt > /tmp/real.txt
xargs -a /tmp/real.txt apt-get download -q >/dev/null
# 2) belt and braces: simulate a real install on this clean base (resolves virtual providers)
apt-get install -y -q --download-only --no-install-recommends "${PKGS[@]}" >/dev/null
cp -n /var/cache/apt/archives/*.deb . 2>/dev/null || true
# 3) never ship two Ceph versions: drop any non-pinned ceph lib/client deb, then assert the pin
for f in ceph-common_* ceph-fuse_* ceph-base_* librados2_* librbd1_* libcephfs2_* libcephfs-proxy2_* libradosstriper1_* librgw2_* libsqlite3-mod-ceph_* python3-ceph*_* python3-rados_* python3-rbd_* python3-cephfs_* python3-rgw_*; do
  [ -e "$f" ] || continue
  case $f in *"_${CEPH_DEB_VERSION}_"*) ;; *) echo "drop non-pinned $f"; rm -f "$f";; esac
done
for p in ceph-common ceph-fuse librados2 librbd1 python3-ceph-common python3-ceph-argparse python3-rados python3-rbd; do
  ls "${p}_${CEPH_DEB_VERSION}_"*.deb >/dev/null 2>&1 || { echo "FATAL: ${p} ${CEPH_DEB_VERSION} not downloaded" >&2; exit 1; }
done
dpkg-scanpackages . /dev/null 2>/dev/null > Packages
gzip -9kf Packages
echo "debs: $(find . -name '*.deb' | wc -l)"
echo "unresolved (virtual/not-needed, check): $(wc -l < unresolved-packages.txt)"
