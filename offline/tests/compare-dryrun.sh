#!/usr/bin/env bash
# Equivalence check: ./deploy.sh --dry-run output of this tree vs. a base git ref, for the same
# cluster.conf (default: cluster.conf.example, i.e. ENABLE_S3_BGP=0). Random mktemp names are
# normalised. Usage: offline/tests/compare-dryrun.sh <base-ref> [cluster.conf]
set -euo pipefail
O=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASE=${1:?usage: $0 <base-ref> [cluster.conf]}
CONFSRC=${2:-$O/cluster.conf.example}
W=$(mktemp -d); trap 'git -C "$O" worktree remove --force "$W/base" >/dev/null 2>&1 || true; rm -rf "$W"' EXIT
git -C "$O" worktree add -q --detach "$W/base" "$BASE"
norm() { sed -E 's#/tmp/[A-Za-z0-9._-]+\.[A-Za-z0-9]{6}([./])#/tmp/TMP\1#g; s#/tmp/tmp\.[A-Za-z0-9]{10}#/tmp/TMP#g; s#\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]#[T]#g'; }
mkdir -p "$W/o" "$W/n"; cp "$CONFSRC" "$W/o/cluster.conf"; cp "$CONFSRC" "$W/n/cluster.conf"
(cd "$W/base/offline" && CONF="$W/o/cluster.conf" bash ./deploy.sh --dry-run 2>&1 | sed "s#$W/o#CONFDIR#g; s#$W/base/offline#OFFLINE#g" | norm) > "$W/base.out" || true
(cd "$O" && CONF="$W/n/cluster.conf" bash ./deploy.sh --dry-run 2>&1 | sed "s#$W/n#CONFDIR#g; s#$O#OFFLINE#g" | norm) > "$W/new.out" || true
if diff -u "$W/base.out" "$W/new.out"; then echo "IDENTICAL ($(wc -l < "$W/new.out") lines) vs $BASE"; else echo "DIFFERENT vs $BASE"; exit 1; fi
