#!/usr/bin/env bash
# Lightweight Ceph bench.
#   nfs: fio against an nfs/nfs4 mount
#   s3:  MinIO warp against the S3 API (not a FUSE mount)
# Does not test RBD or CSI. Defaults stay small on purpose.
set -euo pipefail

TARGET=""
MOUNT=""
RW="randrw"
BS="64k"
SIZE="32M"
RUNTIME="15"
IODEPTH="1"
NUMJOBS="1"
DIRECT="0"
KEEP=0
MIX="50"
ENDPOINT=""
BUCKET="warp-bench"
OBJ_SIZE="64KiB"
OBJECTS="8"
ACCESS_KEY_FILE=""
SECRET_KEY_FILE=""
WARP_BIN=""

usage() {
  cat <<'EOF'
Usage:
  ceph-light-bench.sh --target nfs --mount PATH [options]
  ceph-light-bench.sh --target s3 --endpoint URL [options]

NFS options (fio):
  --rw MODE         read, write, randread, randwrite, randrw (default randrw)
  --bs SIZE         block size (default 64k)
  --size SIZE       file size (default 32M)
  --runtime SEC     seconds (default 15)
  --iodepth N       queue depth (default 1)
  --numjobs N       jobs (default 1)
  --direct 0|1      O_DIRECT (default 0)
  --rwmixread N     percent reads when --rw randrw (default 50)
  --keep            leave the fio file on the mount

S3 options (MinIO warp mixed):
  --endpoint URL    http://host[:port] or https://host[:port]
  --bucket NAME     dedicated bucket (default warp-bench). Warp wipes it.
  --obj-size SIZE   object size (default 64KiB)
  --objects N       object pool size (default 8)
  --concurrent N    warp concurrency (default 1)
  --runtime SEC     duration in seconds (default 15)
  --access-key-file FILE
  --secret-key-file FILE
  --warp PATH       warp binary (default: $WARP, ./warp, ./bin/warp, or PATH)
  Credentials may also be WARP_ACCESS_KEY and WARP_SECRET_KEY.
  They are passed as environment variables and are not printed.

The script prints the plan first. On failure it prints warp or fio's exit
status and the error text, without the secret key.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET=${2:?}; shift 2 ;;
    --mount) MOUNT=${2:?}; shift 2 ;;
    --rw) RW=${2:?}; shift 2 ;;
    --bs) BS=${2:?}; shift 2 ;;
    --size) SIZE=${2:?}; shift 2 ;;
    --runtime) RUNTIME=${2:?}; shift 2 ;;
    --iodepth) IODEPTH=${2:?}; shift 2 ;;
    --numjobs) NUMJOBS=${2:?}; shift 2 ;;
    --direct) DIRECT=${2:?}; shift 2 ;;
    --rwmixread) MIX=${2:?}; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --endpoint) ENDPOINT=${2:?}; shift 2 ;;
    --bucket) BUCKET=${2:?}; shift 2 ;;
    --obj-size) OBJ_SIZE=${2:?}; shift 2 ;;
    --objects) OBJECTS=${2:?}; shift 2 ;;
    --concurrent) NUMJOBS=${2:?}; shift 2 ;;
    --access-key-file) ACCESS_KEY_FILE=${2:?}; shift 2 ;;
    --secret-key-file) SECRET_KEY_FILE=${2:?}; shift 2 ;;
    --warp) WARP_BIN=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$TARGET" ] || die "--target nfs|s3 is required"
case "$TARGET" in
  nfs|s3) ;;
  *) die "--target must be nfs or s3, not '$TARGET'" ;;
esac
[[ "$RUNTIME" =~ ^[0-9]+$ && "$RUNTIME" -ge 1 ]] || die "--runtime must be a positive integer"
[[ "$NUMJOBS" =~ ^[0-9]+$ && "$NUMJOBS" -ge 1 ]] || die "--concurrent/--numjobs must be a positive integer"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

run_nfs() {
  [ -n "$MOUNT" ] || die "--mount is required for nfs"
  case "$RW" in
    read|write|randread|randwrite|randrw) ;;
    *) die "--rw '$RW' is not read|write|randread|randwrite|randrw" ;;
  esac
  [[ "$DIRECT" == 0 || "$DIRECT" == 1 ]] || die "--direct must be 0 or 1"
  [[ "$IODEPTH" =~ ^[0-9]+$ && "$IODEPTH" -ge 1 ]] || die "--iodepth must be a positive integer"
  [[ "$MIX" =~ ^[0-9]+$ && "$MIX" -le 100 ]] || die "--rwmixread must be 0..100"
  command -v fio >/dev/null 2>&1 || die "fio is not installed. Install the fio package, then rerun."
  command -v findmnt >/dev/null 2>&1 || die "findmnt is not installed"
  [ -d "$MOUNT" ] || die "mount path does not exist: $MOUNT"
  if ! findmnt -n "$MOUNT" >/dev/null 2>&1; then
    die "$MOUNT is not a mount point. Mount the nfs filesystem there first."
  fi
  local fstype source
  fstype=$(findmnt -n -o FSTYPE "$MOUNT")
  source=$(findmnt -n -o SOURCE "$MOUNT")
  case "$fstype" in
    nfs|nfs4) ;;
    *) die "$MOUNT is $fstype from $source, not nfs/nfs4" ;;
  esac
  local workdir stamp file
  workdir="$MOUNT/ceph-light-bench"
  mkdir -p "$workdir" || die "cannot create $workdir. Check write permission on the mount."
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  file="$workdir/fio-nfs-${stamp}.dat"
  echo "=== ceph-light-bench ==="
  echo "time:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "target:   nfs"
  echo "tool:     fio $(fio --version | awk '{print $2}')"
  echo "mount:    $MOUNT"
  echo "fstype:   $fstype"
  echo "source:   $source"
  echo "rw:       $RW  bs=$BS  size=$SIZE  runtime=${RUNTIME}s  iodepth=$IODEPTH  numjobs=$NUMJOBS  direct=$DIRECT  rwmixread=$MIX"
  echo "file:     $file"
  echo "=== fio ==="
  set +e
  fio \
    --name="ceph-nfs" \
    --filename="$file" \
    --rw="$RW" \
    --rwmixread="$MIX" \
    --bs="$BS" \
    --size="$SIZE" \
    --runtime="$RUNTIME" \
    --time_based=1 \
    --iodepth="$IODEPTH" \
    --numjobs="$NUMJOBS" \
    --direct="$DIRECT" \
    --ioengine=psync \
    --group_reporting=1 \
    --eta-newline=5
  local rc=$?
  set -e
  if [ "$KEEP" != 1 ]; then
    rm -f "$file" || echo "WARN: could not remove $file"
  fi
  if [ "$rc" -ne 0 ]; then
    die "fio exited $rc. The mount stayed $fstype from $source."
  fi
  echo "=== result ==="
  echo "ok: fio finished on nfs mount $MOUNT ($source)"
}

find_warp() {
  if [ -n "$WARP_BIN" ]; then
    [ -x "$WARP_BIN" ] || die "warp binary is not executable: $WARP_BIN"
    printf '%s\n' "$WARP_BIN"
    return
  fi
  if [ -n "${WARP:-}" ] && [ -x "$WARP" ]; then
    printf '%s\n' "$WARP"
    return
  fi
  if [ -x "$SCRIPT_DIR/warp" ]; then
    printf '%s\n' "$SCRIPT_DIR/warp"
    return
  fi
  if [ -x "$SCRIPT_DIR/bin/warp" ]; then
    printf '%s\n' "$SCRIPT_DIR/bin/warp"
    return
  fi
  if command -v warp >/dev/null 2>&1; then
    command -v warp
    return
  fi
  die "warp not found. Put the MinIO warp binary next to this script or on PATH. Offline package: bin/warp."
}

run_s3() {
  [ -n "$ENDPOINT" ] || die "--endpoint is required for s3, for example http://10.11.4.50"
  [[ "$OBJECTS" =~ ^[0-9]+$ && "$OBJECTS" -ge 1 ]] || die "--objects must be a positive integer"
  local warp_bin host tls scheme
  warp_bin=$(find_warp)
  scheme=${ENDPOINT%%://*}
  host=${ENDPOINT#*://}
  host=${host%%/*}
  case "$scheme" in
    http) tls=false ;;
    https) tls=true ;;
    *) die "--endpoint must start with http:// or https://, got '$ENDPOINT'" ;;
  esac
  case "$host" in
    *:*) ;;
    *)
      if [ "$tls" = true ]; then host="${host}:443"; else host="${host}:80"; fi
      ;;
  esac
  local ak sk
  ak=${WARP_ACCESS_KEY:-}
  sk=${WARP_SECRET_KEY:-}
  if [ -n "$ACCESS_KEY_FILE" ]; then
    [ -r "$ACCESS_KEY_FILE" ] || die "cannot read access key file: $ACCESS_KEY_FILE"
    ak=$(tr -d ' \r\n' < "$ACCESS_KEY_FILE")
  fi
  if [ -n "$SECRET_KEY_FILE" ]; then
    [ -r "$SECRET_KEY_FILE" ] || die "cannot read secret key file: $SECRET_KEY_FILE"
    sk=$(tr -d ' \r\n' < "$SECRET_KEY_FILE")
  fi
  [ -n "$ak" ] || die "S3 access key missing. Set WARP_ACCESS_KEY or --access-key-file."
  [ -n "$sk" ] || die "S3 secret key missing. Set WARP_SECRET_KEY or --secret-key-file."
  local ver bench
  ver=$("$warp_bin" --version 2>/dev/null | head -n 1 || true)
  [ -n "$ver" ] || ver="warp"
  bench=$(mktemp /tmp/warp-bench-XXXXXX.csv.zst)
  echo "=== ceph-light-bench ==="
  echo "time:       $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "target:     s3"
  echo "tool:       $ver"
  echo "binary:     $warp_bin"
  echo "endpoint:   $ENDPOINT"
  echo "host:       $host"
  echo "tls:        $tls"
  echo "bucket:     $BUCKET"
  echo "workload:   mixed  concurrent=$NUMJOBS  objects=$OBJECTS  obj.size=$OBJ_SIZE  duration=${RUNTIME}s"
  echo "note:       warp deletes all objects in this bucket before and after the run"
  echo "=== warp mixed ==="
  set +e
  WARP_HOST="$host" \
  WARP_ACCESS_KEY="$ak" \
  WARP_SECRET_KEY="$sk" \
  WARP_TLS="$tls" \
  "$warp_bin" mixed \
    --duration="${RUNTIME}s" \
    --concurrent="$NUMJOBS" \
    --objects="$OBJECTS" \
    --obj.size="$OBJ_SIZE" \
    --bucket="$BUCKET" \
    --benchdata="$bench"
  local rc=$?
  set -e
  rm -f "$bench" || true
  if [ "$rc" -ne 0 ]; then
    die "warp exited $rc against $ENDPOINT bucket $BUCKET. Check the endpoint, credentials, and that the bucket may be wiped."
  fi
  echo "=== result ==="
  echo "ok: warp mixed finished on $ENDPOINT bucket $BUCKET"
}

case "$TARGET" in
  nfs) run_nfs ;;
  s3) run_s3 ;;
esac
exit 0
