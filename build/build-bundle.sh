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

echo "== container images (from build/images.list)"
# name|pull_ref|basename|digest
while IFS='|' read -r name ref base digest || [ -n "${name:-}" ]; do
  [[ -z "${name:-}" || "$name" =~ ^[[:space:]]*# ]] && continue
  echo "  pull $ref"
  $SUDO podman pull --arch "$ARCH" "$ref"
  inspect="$OUT/images/${name}.inspect"
  $SUDO podman image inspect "$ref" --format '{{.Os}}/{{.Architecture}} {{.Id}} {{.Digest}}' | tee "$inspect"
  tar="$OUT/images/${base}.tar"
  if [ ! -s "$tar" ]; then
    $SUDO podman save --format docker-archive -o "$tar" "$ref"
  fi
  # refresh digest line in inspect note when list had a pin
  if [[ "$digest" == sha256:* ]]; then
    got=$($SUDO podman image inspect "$ref" --format '{{.Digest}}')
    if [ "$got" != "$digest" ]; then
      echo "WARNING: $name digest $got != pinned $digest (updating inspect; re-pin images.list if intentional)" >&2
    fi
  fi
done < "$HERE/images.list"

echo "== debs from clean ubuntu:24.04 container"
$SUDO podman pull --arch "$ARCH" docker.io/library/ubuntu:24.04
$SUDO podman run --rm --network host -v "$OUT/debs:/out:Z" -v "$HERE:/build:ro,Z" docker.io/library/ubuntu:24.04 \
  bash /build/download-debs.sh /out /build/packages.list
$SUDO chown -R "$(id -u):$(id -g)" "$OUT"

echo "== copy offline toolkit + docs"
rm -rf "$OUT/offline" "$OUT/docs"
cp -r "$REPO/offline" "$REPO/docs" "$OUT/"
cp "$HERE/packages.list" "$HERE/images.list" "$OUT/offline/"

echo "== SHA256SUMS"
( cd "$OUT" && find debs images bin offline docs -type f -print0 | sort -z | xargs -0 sha256sum > /tmp/SHA256SUMS.$$ && mv /tmp/SHA256SUMS.$$ SHA256SUMS )
du -sh "$OUT"
if [ "$MAKE_TAR" = 1 ]; then
  T="$(dirname "$OUT")/ceph-offline-${CEPH_VERSION}-vip-bundle.tar"
  tar -C "$(dirname "$OUT")" -cf "$T" "$(basename "$OUT")"
  sha256sum "$T" | tee "$T.sha256"
fi
