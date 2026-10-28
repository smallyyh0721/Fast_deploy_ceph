#!/usr/bin/env bash
# Read-only export of cluster metadata into one dated tar (mode 600). NOT part of deploy.sh,
# installs no cron/timer -- run it by hand (or schedule it yourself: docs/backup.md).
#   sudo ./backup-cluster-meta.sh [--out DIR] [--dry-run]
# DIR: --out > BACKUP_DIR (env or cluster.conf) > /var/backups/ceph-meta
# Contents: /etc/ceph, auth ls, config dump, config-key dump, orch ls --export, orch host ls,
#   crushmap (binary + decompiled json), mon/osd/fs dump, versions, mgr services,
#   rgw realm/zonegroup/zone/period (when RGW is configured).
# The tar holds keyrings and every CephX secret: keep it 600, off the cluster, encrypted at rest.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
OUTDIR=""
while [ $# -gt 0 ]; do
  case $1 in
    --out) OUTDIR=${2:?--out needs a directory}; shift;;
    --dry-run) DRY_RUN=1;;
    -h|--help) sed -n '2,10p' "$0"; exit 0;;
    *) die "unknown arg $1";;
  esac; shift
done
[ ! -f "$CONF" ] || load_conf          # optional: only for BACKUP_DIR
OUTDIR=${OUTDIR:-${BACKUP_DIR:-/var/backups/ceph-meta}}
[[ $OUTDIR == /* ]] || die "output dir must be absolute: $OUTDIR"
STAMP=$(date +%Y%m%d-%H%M%S)
CEPH_ETC=${CEPH_ETC:-/etc/ceph}

# name|command (ceph subcommand, run read-only through cephadm shell, stdin closed)
ITEMS=(
  "status.txt|ceph -s"
  "versions.json|ceph versions --format json-pretty"
  "auth-ls.txt|ceph auth ls"
  "config-dump.txt|ceph config dump"
  "config-key-dump.json|ceph config-key dump"
  "orch-ls-export.yaml|ceph orch ls --export"
  "orch-host-ls.txt|ceph orch host ls"
  "crushmap.bin|ceph osd getcrushmap"
  "crush-dump.json|ceph osd crush dump --format json-pretty"
  "mon-dump.txt|ceph mon dump"
  "osd-dump.txt|ceph osd dump"
  "osd-tree.txt|ceph osd tree"
  "fs-dump.txt|ceph fs dump"
  "mgr-services.json|ceph mgr services"
  "rgw-realm-list.json|radosgw-admin realm list"
  "rgw-zonegroup-get.json|radosgw-admin zonegroup get"
  "rgw-zone-get.json|radosgw-admin zone get"
  "rgw-period-get.json|radosgw-admin period get"
)
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] umask 077; mkdir -p $OUTDIR (chmod 700)"
  echo "  [dry-run] copy $CEPH_ETC -> etc-ceph/"
  for it in "${ITEMS[@]}"; do echo "  [dry-run] cephadm shell -- ${it#*|} </dev/null > ${it%%|*}"; done
  echo "  [dry-run] tar czf $OUTDIR/ceph-meta-<fsid>-$STAMP.tar.gz (chmod 600), remove work dir"
  exit 0
fi
need_root
command -v cephadm >/dev/null || die "cephadm not found (run on an admin node: $(hostname -s))"
[ -f "$CEPH_ETC/ceph.conf" ] || die "$CEPH_ETC/ceph.conf missing (run on a node with the _admin label)"
FSID=$(awk '$1=="fsid" {print $3}' "$CEPH_ETC/ceph.conf" | head -n1)
umask 077
mkdir -p "$OUTDIR"; chmod 700 "$OUTDIR"
NAME="ceph-meta-${FSID:-unknown}-$STAMP"
W=$(mktemp -d "$OUTDIR/.$NAME.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/$NAME"
cp -a "$CEPH_ETC" "$W/$NAME/etc-ceph"
FAILED=()
for it in "${ITEMS[@]}"; do
  f=${it%%|*}; read -ra cmd <<<"${it#*|}"
  if cephadm shell -- "${cmd[@]}" </dev/null > "$W/$NAME/$f" 2>"$W/$NAME/$f.err"; then
    rm -f "$W/$NAME/$f.err"; echo "  ok   $f"
  else
    case $f in rgw-*) echo "  skip $f (no RGW realm/zone?)";; *) echo "  FAIL $f"; FAILED+=("$f");; esac
  fi
done
{ echo "created=$(date -Is)"; echo "host=$(hostname -s)"; echo "fsid=$FSID"; echo "failed=${FAILED[*]:-}"; } > "$W/$NAME/MANIFEST.txt"
( cd "$W/$NAME" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
T="$OUTDIR/$NAME.tar.gz"
tar -C "$W" -czf "$T.tmp" "$NAME"; chmod 600 "$T.tmp"; mv "$T.tmp" "$T"
log "backup: $T ($(stat -c %s "$T") bytes, mode $(stat -c %a "$T"))"
[ "${#FAILED[@]}" -eq 0 ] || die "some items failed: ${FAILED[*]} (their .err files are in the tar)"
