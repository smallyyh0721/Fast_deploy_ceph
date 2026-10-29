#!/usr/bin/env bash
# Lightweight fio benchmark for a Ceph NFS mount or an S3 FUSE mount.
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

usage() {
  cat <<'EOF'
Usage: ceph-light-bench.sh --target nfs|s3 --mount PATH [options]

Options:
  --rw MODE         read, write, randread, randwrite, randrw (default randrw)
  --bs SIZE         block size (default 64k)
  --size SIZE       file size (default 32M)
  --runtime SEC     seconds (default 15)
  --iodepth N       queue depth (default 1)
  --numjobs N       jobs (default 1)
  --direct 0|1      O_DIRECT (default 0; FUSE/S3 usually needs 0)
  --rwmixread N     percent reads when --rw randrw (default 50)
  --keep            leave the fio file on the mount
  -h, --help

The mount must already be mounted. nfs must be nfs/nfs4.
s3 must be a FUSE mount whose type contains s3, rclone, or geesefs.
Requires fio. Prints the plan first, then fio's summary, and on failure
the command and fio's exit status.
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
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$TARGET" ] || die "--target nfs|s3 is required"
[ -n "$MOUNT" ] || die "--mount is required"
case "$TARGET" in
  nfs|s3) ;;
  *) die "--target must be nfs or s3, not '$TARGET'" ;;
esac
case "$RW" in
  read|write|randread|randwrite|randrw) ;;
  *) die "--rw '$RW' is not read|write|randread|randwrite|randrw" ;;
esac
[[ "$DIRECT" == 0 || "$DIRECT" == 1 ]] || die "--direct must be 0 or 1"
[[ "$RUNTIME" =~ ^[0-9]+$ && "$RUNTIME" -ge 1 ]] || die "--runtime must be a positive integer"
[[ "$IODEPTH" =~ ^[0-9]+$ && "$IODEPTH" -ge 1 ]] || die "--iodepth must be a positive integer"
[[ "$NUMJOBS" =~ ^[0-9]+$ && "$NUMJOBS" -ge 1 ]] || die "--numjobs must be a positive integer"
[[ "$MIX" =~ ^[0-9]+$ && "$MIX" -le 100 ]] || die "--rwmixread must be 0..100"

command -v fio >/dev/null 2>&1 || die "fio is not installed. Install the fio package, then rerun."
command -v findmnt >/dev/null 2>&1 || die "findmnt is not installed"

[ -d "$MOUNT" ] || die "mount path does not exist: $MOUNT"
if ! findmnt -n "$MOUNT" >/dev/null 2>&1; then
  die "$MOUNT is not a mount point. Mount the $TARGET filesystem there first."
fi
FSTYPE=$(findmnt -n -o FSTYPE "$MOUNT")
SOURCE=$(findmnt -n -o SOURCE "$MOUNT")
case "$TARGET" in
  nfs)
    case "$FSTYPE" in
      nfs|nfs4) ;;
      *) die "$MOUNT is $FSTYPE from $SOURCE, not nfs/nfs4" ;;
    esac
    ;;
  s3)
    case "$FSTYPE" in
      *s3*|*rclone*|*geesefs*|*goofys*) ;;
      *) die "$MOUNT is $FSTYPE from $SOURCE. Expected a FUSE S3 mount (s3fs, rclone, geesefs, or goofys)." ;;
    esac
    ;;
esac

WORKDIR="$MOUNT/ceph-light-bench"
if ! mkdir -p "$WORKDIR"; then
  die "cannot create $WORKDIR. Check write permission on the mount."
fi
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
FILE="$WORKDIR/fio-${TARGET}-${STAMP}.dat"

echo "=== ceph-light-bench ==="
echo "time:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "target:   $TARGET"
echo "mount:    $MOUNT"
echo "fstype:   $FSTYPE"
echo "source:   $SOURCE"
echo "fio:      $(fio --version)"
echo "rw:       $RW  bs=$BS  size=$SIZE  runtime=${RUNTIME}s  iodepth=$IODEPTH  numjobs=$NUMJOBS  direct=$DIRECT  rwmixread=$MIX"
echo "file:     $FILE"
echo "=== fio ==="

set +e
fio \
  --name="ceph-${TARGET}" \
  --filename="$FILE" \
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
RC=$?
set -e

if [ "$KEEP" != 1 ]; then
  rm -f "$FILE" || echo "WARN: could not remove $FILE"
fi

if [ "$RC" -ne 0 ]; then
  die "fio exited $RC. The mount stayed $FSTYPE from $SOURCE. Check dmesg, df, and that the server still exports this path."
fi
echo "=== result ==="
echo "ok: fio finished on $TARGET mount $MOUNT ($SOURCE)"
exit 0
