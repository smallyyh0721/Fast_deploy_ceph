#!/usr/bin/env bash
# Run on an INTERNET-connected x86_64 machine with podman + curl.
# Produces: $OUT/{debs,images,bin,offline,docs} + SHA256SUMS (+ optional tarball)
set -euo pipefail
CEPH_VERSION=${CEPH_VERSION:-20.2.4}
ARCH=${ARCH:-amd64}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=${OUT:-$REPO/../Fast_deploy_ceph-bundle}
MAKE_TAR=${MAKE_TAR:-1}
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo
mkdir -p "$OUT"/{debs,images,bin}

echo "== cephadm $CEPH_VERSION"
if [ ! -s "$OUT/bin/cephadm" ]; then
  curl -fL --retry 3 "https://download.ceph.com/rpm-${CEPH_VERSION}/el9/noarch/cephadm" -o "$OUT/bin/cephadm"
fi
chmod +x "$OUT/bin/cephadm"
python3 "$OUT/bin/cephadm" version | tee "$OUT/bin/cephadm.version"

echo "== container images"
for img in "quay.io/ceph/ceph:v${CEPH_VERSION}" "docker.io/library/registry:2"; do
  $SUDO podman pull --arch "$ARCH" "$img"
done
$SUDO podman image inspect "quay.io/ceph/ceph:v${CEPH_VERSION}" --format '{{.Os}}/{{.Architecture}} {{.Id}} {{.Digest}}' | tee "$OUT/images/ceph.inspect"
[ -s "$OUT/images/ceph-v${CEPH_VERSION}.tar" ] || $SUDO podman save --format docker-archive -o "$OUT/images/ceph-v${CEPH_VERSION}.tar" "quay.io/ceph/ceph:v${CEPH_VERSION}"
[ -s "$OUT/images/registry-2.tar" ] || $SUDO podman save --format docker-archive -o "$OUT/images/registry-2.tar" docker.io/library/registry:2

echo "== debs from clean ubuntu:24.04 container"
$SUDO podman pull --arch "$ARCH" docker.io/library/ubuntu:24.04
$SUDO podman run --rm --network host -v "$OUT/debs:/out:Z" -v "$HERE:/build:ro,Z" docker.io/library/ubuntu:24.04 \
  bash /build/download-debs.sh /out /build/packages.list
$SUDO chown -R "$(id -u):$(id -g)" "$OUT"

echo "== copy offline toolkit + docs"
rm -rf "$OUT/offline" "$OUT/docs"
cp -r "$REPO/offline" "$REPO/docs" "$OUT/"
cp "$HERE/packages.list" "$OUT/offline/"

echo "== SHA256SUMS"
( cd "$OUT" && find debs images bin offline docs -type f -print0 | sort -z | xargs -0 sha256sum > /tmp/SHA256SUMS.$$ && mv /tmp/SHA256SUMS.$$ SHA256SUMS )
du -sh "$OUT"
if [ "$MAKE_TAR" = 1 ]; then
  T="$(dirname "$OUT")/ceph-offline-${CEPH_VERSION}-bundle.tar"
  tar -C "$(dirname "$OUT")" -cf "$T" "$(basename "$OUT")"
  sha256sum "$T" | tee "$T.sha256"
fi
