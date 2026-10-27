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
dpkg-scanpackages . /dev/null 2>/dev/null > Packages
gzip -9kf Packages
echo "debs: $(find . -name '*.deb' | wc -l)"
echo "unresolved (virtual/not-needed, check): $(wc -l < unresolved-packages.txt)"
