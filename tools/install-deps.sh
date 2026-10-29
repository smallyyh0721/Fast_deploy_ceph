#!/usr/bin/env bash
# Install bundled .debs without downgrading packages already on the system.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
shopt -s nullglob
debs=("$DIR"/debs/*.deb)
[ "${#debs[@]}" -gt 0 ] || { echo "ERROR: no debs in $DIR/debs" >&2; exit 1; }
command -v dpkg >/dev/null 2>&1 || { echo "ERROR: dpkg is required" >&2; exit 1; }

install=()
for deb in "${debs[@]}"; do
  pkg=$(dpkg-deb -f "$deb" Package)
  ver=$(dpkg-deb -f "$deb" Version)
  inst=$(dpkg-query -W -f '${Version}' "$pkg" 2>/dev/null || true)
  if [ -z "$inst" ]; then
    echo "INSTALL $pkg $ver"
    install+=("$deb")
  elif dpkg --compare-versions "$inst" ge "$ver"; then
    echo "SKIP    $pkg installed $inst (bundle $ver)"
  else
    echo "UPGRADE $pkg $inst -> $ver"
    install+=("$deb")
  fi
done

if [ "${#install[@]}" -eq 0 ]; then
  echo "dependencies already satisfied"
  exit 0
fi
echo "=== dpkg -i ${#install[@]} package(s) ==="
dpkg -i "${install[@]}"
echo "ok: dependencies installed"
