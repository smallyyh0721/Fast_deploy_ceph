#!/usr/bin/env bash
# Unit tests for disk-safety.sh classify (mock lsblk/pvs/lvs snapshots). Run: ./tests/test-disk-safety.sh
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd); DS="$T/../disk-safety.sh"; F="$T/fixtures"
FSID=11111111-2222-3333-4444-555555555555
pass=0; fail=0
expect() { # snapshot path expected-action [detail-substring]
  local out act
  out=$("$DS" classify "$F/$1" nodeX --fsid "$FSID" "$2" | tail -n1); act=${out%%|*}
  if [ "$act" = "$3" ] && [[ $out == *"${4:-}"* ]]; then pass=$((pass+1)); echo "ok   $1 $2 -> $act"
  else fail=$((fail+1)); echo "FAIL $1 $2 -> $out (want $3 ${4:-})"; fi
}
expect node-a.snap /dev/disk/by-id/ata-SAMSUNG_ROOT REFUSE "backs /"
expect node-a-norootinfo.snap /dev/disk/by-id/ata-SAMSUNG_ROOT REFUSE "mounted: /,/boot,/boot/efi"
expect node-a.snap /dev/disk/by-id/ata-SAMSUNG_ROOT-part3 REFUSE partition
expect node-a.snap /dev/disk/by-id/nvme-CLEAN CREATE clean
expect node-a.snap /dev/disk/by-id/nvme-OLD NEEDS-ZAP xfs
expect node-a.snap /dev/disk/by-id/nvme-OSD SKIP "already an OSD"
expect node-a.snap /dev/disk/by-id/nvme-OTHER REFUSE "another/unknown cluster"
expect node-a.snap /dev/disk/by-id/ata-DATAVG REFUSE "non-Ceph LVM"
expect node-a.snap /dev/disk/by-id/ata-MD REFUSE "md RAID"
expect node-a.snap /dev/disk/by-id/ata-SWAP REFUSE swap
expect node-a.snap /dev/disk/by-id/nvme-MISSING REFUSE "does not resolve"
expect node-a.snap /dev/nvme0n1 REFUSE "not a /dev/disk/by-id"
expect node-md.snap /dev/disk/by-id/ata-MDA REFUSE "backs /"
expect node-md.snap /dev/disk/by-id/ata-MDB REFUSE "backs /"
expect node-md.snap /dev/disk/by-id/md-name-root REFUSE "not a whole disk"
# no fsid known (fresh cluster): any Ceph LVM must be refused, not skipped
out=$("$DS" classify "$F/node-a.snap" nodeX /dev/disk/by-id/nvme-OSD); [[ $out == REFUSE* ]] && { pass=$((pass+1)); echo "ok   no-fsid ceph LVM -> REFUSE"; } || { fail=$((fail+1)); echo "FAIL no-fsid: $out"; }
# duplicate physical disk via two by-id aliases -> both refused
out=$("$DS" classify "$F/node-a.snap" nodeX --fsid "$FSID" /dev/disk/by-id/nvme-CLEAN /dev/disk/by-id/nvme-CLEAN-alias)
[ "$(grep -c '^REFUSE|.*more than once' <<<"$out")" = 2 ] && { pass=$((pass+1)); echo "ok   duplicate -> REFUSE x2"; } || { fail=$((fail+1)); echo "FAIL dup: $out"; }
# confirm gate (add-osds.sh helpers)
. "$T/../add-osds.sh" --source-only
PLAN_TEST=$'CREATE|n1|/dev/disk/by-id/nvme-CLEAN|nvme0n1|1|m|PHLJ0000CLEAN|0|clean\nNEEDS-ZAP|n1|/dev/disk/by-id/nvme-OLD|nvme1n1|1|m|PHLJ0000OLDX|0|x'
c() { FDC_CONFIRM_ALLOW_NONTTY=1 confirm_plan <<<"$PLAN_TEST" 3<<<"$1" >/dev/null 2>&1; }
if c $'YES-WIPE-2\nOLDX'; then pass=$((pass+1)); echo "ok   confirm correct"; else fail=$((fail+1)); echo "FAIL confirm correct"; fi
if c $'YES-WIPE-1\nOLDX'; then fail=$((fail+1)); echo "FAIL wrong N accepted"; else pass=$((pass+1)); echo "ok   wrong N rejected"; fi
if c $'YES-WIPE-2\nXXXX'; then fail=$((fail+1)); echo "FAIL wrong serial accepted"; else pass=$((pass+1)); echo "ok   wrong serial rejected"; fi
if c $'yes'; then fail=$((fail+1)); echo "FAIL 'yes' accepted"; else pass=$((pass+1)); echo "ok   plain yes rejected"; fi
# ---- probe / ssh helpers (issue #1): no bash -s stream; ssh -n; strict host-key knobs ----
AO="$T/../add-osds.sh"; LIB="$T/../lib.sh"
# remote probe must scp + execute by path, never stream script via bash -s
if grep -E 'bash[[:space:]]+-s' "$AO" | grep -qvE '^[[:space:]]*#'; then
  fail=$((fail+1)); echo "FAIL add-osds still uses bash -s for remote probe"
else pass=$((pass+1)); echo "ok   probe does not use bash -s"; fi
grep -q 'scp .*disk-safety.sh' "$AO" && grep -q 'REMOTE_DISK_SAFETY\|offline/disk-safety.sh' "$AO" \
  && { pass=$((pass+1)); echo "ok   probe scp + remote path"; } \
  || { fail=$((fail+1)); echo "FAIL probe missing scp/remote path"; }
# ssh_node closes stdin; ssh_node_in exists for rare streaming callers
grep -qE 'ssh_node\(\).*ssh -n|ssh -n "\$\{SSH_OPTS' "$LIB" \
  && { pass=$((pass+1)); echo "ok   ssh_node uses ssh -n"; } \
  || { fail=$((fail+1)); echo "FAIL ssh_node missing -n"; }
grep -q 'ssh_node_in()' "$LIB" \
  && { pass=$((pass+1)); echo "ok   ssh_node_in present"; } \
  || { fail=$((fail+1)); echo "FAIL ssh_node_in missing"; }
# ceph_ closes stdin so apply-plan cannot be drained
grep -q 'cephadm shell -- ceph "$@" </dev/null' "$LIB" \
  && { pass=$((pass+1)); echo "ok   ceph_ closes stdin"; } \
  || { fail=$((fail+1)); echo "FAIL ceph_ stdin not closed"; }
# ssh_build_opts: default accept-new; strict + known_hosts when set
W=$(mktemp -d); trap 'rm -rf "$W"' RETURN
cat > "$W/c.conf" <<'C'
NODE_NAMES=(node1); NODE_IPS=(127.0.0.1); PUBLIC_NETWORK=127.0.0.0/8
CEPH_VERSION=20.2.4; REGISTRY_PORT=5000; BUNDLE_DIR=/opt/ceph-offline
OSD_DEVICES=("node1:/dev/disk/by-id/x"); POOL_SIZE=1; POOL_MIN_SIZE=1
C
opts_of() { # print SSH_OPTS joined
  env -i PATH="$PATH" HOME="$HOME" CONF="$W/c.conf" bash -c '
    set -euo pipefail
    . "'"$LIB"'"
    '"$1"'
    load_conf
    printf "%s\n" "${SSH_OPTS[*]}"
  '
}
o=$(opts_of ''); [[ $o == *StrictHostKeyChecking=accept-new* ]] \
  && { pass=$((pass+1)); echo "ok   default accept-new"; } \
  || { fail=$((fail+1)); echo "FAIL default opts: $o"; }
o=$(opts_of 'SSH_STRICT_HOSTKEY=1; SSH_KNOWN_HOSTS=/tmp/kh.test')
[[ $o == *StrictHostKeyChecking=yes* && $o == *UserKnownHostsFile=/tmp/kh.test* && $o != *accept-new* ]] \
  && { pass=$((pass+1)); echo "ok   strict + UserKnownHostsFile"; } \
  || { fail=$((fail+1)); echo "FAIL strict opts: $o"; }
# conf file knobs
cat >> "$W/c.conf" <<'C'
SSH_STRICT_HOSTKEY=1
SSH_KNOWN_HOSTS=/etc/fast-deploy/known_hosts
C
o=$(opts_of '')
[[ $o == *StrictHostKeyChecking=yes* && $o == *UserKnownHostsFile=/etc/fast-deploy/known_hosts* ]] \
  && { pass=$((pass+1)); echo "ok   conf SSH_STRICT_HOSTKEY/SSH_KNOWN_HOSTS"; } \
  || { fail=$((fail+1)); echo "FAIL conf opts: $o"; }
# deploy install stage uses ssh_node (closed stdin), not bare ssh without -n
if grep -E 'run ssh "\$\{SSH_OPTS' "$T/../deploy.sh" | grep -qvE '^[[:space:]]*#'; then
  fail=$((fail+1)); echo "FAIL deploy.sh still uses ssh without ssh_node/-n"
else pass=$((pass+1)); echo "ok   deploy install uses ssh_node"; fi

# ---- env vs conf precedence (conf assignment > exported env > default) ----
OFF=$T/..
cat > "$W/base.conf" <<'C'
NODE_NAMES=(node1); NODE_IPS=(127.0.0.1); PUBLIC_NETWORK=127.0.0.0/8
CEPH_VERSION=20.2.4; REGISTRY_PORT=5000; BUNDLE_DIR=/opt/ceph-offline
OSD_DEVICES=("node1:/dev/disk/by-id/x"); POOL_SIZE=1; POOL_MIN_SIZE=1
C
optsx() { # optsx CONFFILE [VAR=val ...]  -> SSH_OPTS with given *environment* (not set in-script)
  local cf=$1; shift
  env -i PATH="$PATH" HOME="$HOME" CONF="$cf" "$@" bash -c '
    set -euo pipefail
    . "'"$LIB"'"
    load_conf
    printf "%s\n" "${SSH_OPTS[*]}"
  '
}
chk() { # name cond-result
  if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: $o"; fi
}
# cluster.conf.example must not hard-assign the SSH knobs (would silently override env)
if grep -qE '^[[:space:]]*(SSH_STRICT_HOSTKEY|SSH_KNOWN_HOSTS|SSH_CONNECT_TIMEOUT)=' "$OFF/cluster.conf.example"; then
  fail=$((fail+1)); echo "FAIL cluster.conf.example hard-assigns SSH_* knobs"
else pass=$((pass+1)); echo "ok   cluster.conf.example leaves SSH_* knobs commented"; fi
# example's SSH block (commented) appended to a base conf: env must win
{ cat "$W/base.conf"; sed -n '/^# SSH from node1/,/sudo drops env/p' "$OFF/cluster.conf.example"; } > "$W/ex.conf"
if grep -q 'SSH_STRICT_HOSTKEY' "$W/ex.conf"; then r=0; else r=1; fi; chk "example SSH block extracted" $r
o=$(optsx "$W/ex.conf"); if [[ $o == *accept-new* && $o != *UserKnownHostsFile* ]]; then r=0; else r=1; fi; chk "example conf, no env -> accept-new default" $r
o=$(optsx "$W/ex.conf" SSH_STRICT_HOSTKEY=1 SSH_KNOWN_HOSTS=/env/kh)
if [[ $o == *StrictHostKeyChecking=yes* && $o == *UserKnownHostsFile=/env/kh* && $o != *accept-new* ]]; then r=0; else r=1; fi; chk "example conf + env strict/known_hosts -> env applies" $r
o=$(optsx "$W/base.conf" SSH_STRICT_HOSTKEY=yes); if [[ $o == *StrictHostKeyChecking=yes* ]]; then r=0; else r=1; fi; chk "env SSH_STRICT_HOSTKEY=yes accepted" $r
o=$(optsx "$W/base.conf" SSH_CONNECT_TIMEOUT=3); if [[ $o == *ConnectTimeout=3* ]]; then r=0; else r=1; fi; chk "env SSH_CONNECT_TIMEOUT applies" $r
# explicit conf assignment beats env (documented precedence)
{ cat "$W/base.conf"; printf 'SSH_STRICT_HOSTKEY=0\nSSH_KNOWN_HOSTS=/conf/kh\n'; } > "$W/cw.conf"
o=$(optsx "$W/cw.conf" SSH_STRICT_HOSTKEY=1 SSH_KNOWN_HOSTS=/env/kh)
if [[ $o == *accept-new* && $o == *UserKnownHostsFile=/conf/kh* && $o != */env/kh* ]]; then r=0; else r=1; fi; chk "conf assignment overrides env" $r
{ cat "$W/base.conf"; printf 'SSH_STRICT_HOSTKEY=1\n'; } > "$W/cs.conf"
o=$(optsx "$W/cs.conf"); if [[ $o == *StrictHostKeyChecking=yes* ]]; then r=0; else r=1; fi; chk "conf-only strict" $r
# ${VAR-default} form in conf lets env override (documented opt-in)
{ cat "$W/base.conf"; printf 'SSH_STRICT_HOSTKEY=${SSH_STRICT_HOSTKEY-1}\n'; } > "$W/cd.conf"
o=$(optsx "$W/cd.conf"); if [[ $o == *StrictHostKeyChecking=yes* ]]; then r=0; else r=1; fi; chk "conf \${VAR-1} default when env unset" $r
o=$(optsx "$W/cd.conf" SSH_STRICT_HOSTKEY=0); if [[ $o == *accept-new* ]]; then r=0; else r=1; fi; chk "conf \${VAR-1} -> env 0 wins" $r
# ---- every cephadm shell call closes stdin (drains while-read loops otherwise) ----
o=$(grep -nE '(^|[^-_[:alnum:]])cephadm shell' "$OFF"/*.sh "$OFF"/s3-bgp/*.sh \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
      | grep -vE '(echo|log) "[^"]*cephadm shell|CMDS\+=\("cephadm shell' \
      | grep -v '</dev/null' || true)
if [ -z "$o" ]; then r=0; else r=1; fi; chk "no bare cephadm shell without </dev/null in offline/*.sh" $r
o=setup-pools; if grep -q 'run cephadm shell -- rbd pool init "$name" </dev/null' "$OFF/setup-pools.sh"; then r=0; else r=1; fi; chk "setup-pools rbd pool init closes stdin" $r
o=setup-rgw; if grep -qE '^rgwadm\(\) \{ cephadm shell -- radosgw-admin "\$@" </dev/null; \}' "$OFF/setup-rgw.sh"; then r=0; else r=1; fi; chk "setup-rgw rgwadm closes stdin" $r
o=verify; if grep -q 'cephadm shell -- "${w\[@\]}" </dev/null' "$OFF/verify.sh"; then r=0; else r=1; fi; chk "verify.sh CHECKS loop closes stdin" $r
# behavioural: a read loop calling the stdin-closed helpers is not drained
o=$(env -i PATH="$PATH" bash -c '
  cephadm() { cat >/dev/null; }      # mock: drains stdin like `cephadm shell` does
  rgwadm() { cephadm shell -- radosgw-admin "$@" </dev/null; }
  n=0; while read -r _; do rgwadm x; n=$((n+1)); done <<<"$(printf "a\nb\nc\n")"; echo $n')
if [ "$o" = 3 ]; then r=0; else r=1; fi; chk "read loop survives stdin-closed cephadm (3 iterations)" $r
# ---- remote disk-safety.sh copy is atomic: scp to .tmp then mv ----
o=$(env -i PATH="$PATH" HOME="$HOME" bash -c '
  set -euo pipefail
  . "'"$OFF"'/add-osds.sh" --source-only
  BUNDLE_DIR=/opt/b
  hostname() { echo adminnode; }
  node_ip() { echo 10.9.9.2; }
  ssh_node() { shift; echo "SSH $*"; }
  scp() { echo "SCP ${*: -2}"; }
  probe_host node2 /dev/disk/by-id/a 2>&1')
tmpl=$(sed -n 's/^SCP .* root@10\.9\.9\.2:\(.*\)$/\1/p' <<<"$o")
if [[ $tmpl == /opt/b/offline/disk-safety.sh.tmp.* ]]; then r=0; else r=1; fi; chk "scp targets <path>.tmp.*" $r
if grep -q "mv -f $tmpl /opt/b/offline/disk-safety.sh" <<<"$o"; then r=0; else r=1; fi; chk "ssh mv tmp -> final path" $r
if [ "$(grep -cE '^SSH mkdir|^SCP|mv -f|^SSH bash ' <<<"$o")" = 4 ] && [[ $(grep -nE '' <<<"$o" | awk -F: '/SSH mkdir/{a=$1}/SCP/{b=$1}/mv -f/{c=$1}/SSH bash/{d=$1}END{print (a<b&&b<c&&c<d)?"y":"n"}') == y ]]; then r=0; else r=1; fi; chk "probe order mkdir->scp tmp->mv->bash path" $r
o=$(grep -nE 'scp .*root@\$ip:\$remote"' "$OFF/add-osds.sh" || true); if [ -z "$o" ]; then r=0; else r=1; fi; chk "add-osds never scps directly onto final path" $r
# ---- probe_host failure paths (caller is `probe_host ... || die`: set -e is OFF inside) ----
probe_sim() { # probe_sim FAILSTEP [REMOTE_DISK_SAFETY] -> log lines, last line "RC=<n>"
  env -i PATH="$PATH" HOME="$HOME" FAILSTEP="$1" RDS="${2:-}" bash -c '
    set -euo pipefail
    . "'"$OFF"'/add-osds.sh" --source-only
    BUNDLE_DIR=/opt/b; [ -z "$RDS" ] || REMOTE_DISK_SAFETY=$RDS
    hostname() { echo adminnode; }
    node_ip() { echo 10.9.9.2; }
    ssh_node() { shift; echo "SSH $*"
      case "$FAILSTEP:$*" in
        mkdir:mkdir*|mv:chmod*|probe:bash*) return 1;;
      esac; }
    scp() { echo "SCP ${*: -1}"; [ "$FAILSTEP" != scp ]; }
    rc=0; probe_host node2 "/dev/disk/by-id/a b" "/dev/x;rm" 2>/dev/null || rc=$?
    echo "RC=$rc"'
}
TMPRX='/opt/b/offline/disk-safety\.sh\.tmp\.[0-9]+'
for step in scp mv; do
  o=$(probe_sim $step)
  if grep -q '^RC=[1-9]' <<<"$o"; then r=0; else r=1; fi; chk "$step failure -> probe_host non-zero (|| context)" $r
  if grep -q '^SSH bash ' <<<"$o"; then r=1; else r=0; fi; chk "$step failure -> remote script NOT executed" $r
  if grep -qE "^SSH rm -f $TMPRX\$" <<<"$o"; then r=0; else r=1; fi; chk "$step failure -> rm -f .tmp attempted" $r
done
o=$(probe_sim scp)
if grep -q 'mv -f' <<<"$o"; then r=1; else r=0; fi; chk "scp failure -> no mv of partial .tmp" $r
o=$(probe_sim mkdir)
if grep -q '^RC=[1-9]' <<<"$o" && ! grep -qE '^SCP|^SSH bash ' <<<"$o"; then r=0; else r=1; fi; chk "mkdir failure -> non-zero, no scp/run" $r
o=$(probe_sim probe)
if grep -q '^RC=[1-9]' <<<"$o"; then r=0; else r=1; fi; chk "remote probe failure -> non-zero" $r
o=$(probe_sim none)
if grep -q '^RC=0$' <<<"$o" && [ "$(grep -c '^SSH rm -f' <<<"$o")" = 0 ]; then r=0; else r=1; fi; chk "success path rc=0, no cleanup" $r
if grep -qF 'SSH bash /opt/b/offline/disk-safety.sh probe /dev/disk/by-id/a\ b /dev/x\;rm' <<<"$o"; then r=0; else r=1; fi; chk "remote probe args quoted with %q" $r
o=$(probe_sim none '/opt/x y/$(id)/ds.sh')
if grep -q '^RC=[1-9]' <<<"$o" && ! grep -qE '^SSH|^SCP' <<<"$o"; then r=0; else r=1; fi; chk "unsafe REMOTE_DISK_SAFETY rejected before any ssh" $r
if grep -q 'a partial write never runs' "$OFF/add-osds.sh"; then r=1; else r=0; fi; o=comment; chk "misleading comment removed" $r
# ---- SSH_STRICT_HOSTKEY must be a known value ----
o=$(optsx "$W/base.conf" SSH_STRICT_HOSTKEY=maybe 2>&1) && r=1 || r=0
if [ "$r" = 0 ] && [[ $o == *"SSH_STRICT_HOSTKEY='maybe' is invalid"* ]]; then r=0; else r=1; fi; chk "invalid env SSH_STRICT_HOSTKEY errors" $r
{ cat "$W/base.conf"; printf 'SSH_STRICT_HOSTKEY=strict\n'; } > "$W/bad.conf"
o=$(optsx "$W/bad.conf" 2>&1) && r=1 || r=0
if [ "$r" = 0 ] && [[ $o == *"invalid SSH settings"* ]]; then r=0; else r=1; fi; chk "invalid conf SSH_STRICT_HOSTKEY errors in load_conf" $r
for v in 0 no false 1 yes true; do o=$(optsx "$W/base.conf" SSH_STRICT_HOSTKEY=$v 2>&1) || o="ERR $o"; [[ $o != ERR* ]] || break; done
if [[ $o != ERR* ]]; then r=0; else r=1; fi; chk "valid SSH_STRICT_HOSTKEY values accepted" $r
echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
