#!/usr/bin/env bash
# Run on node1. Default: PRINT the manual add-host commands for nodes 2..N.
#   ./add-hosts.sh            # print commands only (recommended: run them by hand)
#   ./add-hosts.sh --apply    # execute them (requires root ssh to peers already working)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_conf
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

MON_N=${#NODE_NAMES[@]}; [ "$MON_N" -gt 3 ] && MON_N=3
MGR_N=2; [ "${#NODE_NAMES[@]}" -lt 2 ] && MGR_N=1
CMDS=()
for i in "${!NODE_NAMES[@]}"; do
  [ "$i" -eq 0 ] && continue
  n=${NODE_NAMES[$i]}; ip=${NODE_IPS[$i]}
  CMDS+=("ssh-copy-id -f -i /etc/ceph/ceph.pub root@$ip   # or append /etc/ceph/ceph.pub to $n:/root/.ssh/authorized_keys")
  CMDS+=("cephadm shell -- ceph orch host add $n $ip --labels mon,mgr")
done
CMDS+=("cephadm shell -- ceph orch apply mon --placement=\"$MON_N label:mon\"")
CMDS+=("cephadm shell -- ceph orch apply mgr --placement=\"$MGR_N label:mgr\"")
CMDS+=("cephadm shell -- ceph orch host ls")
CMDS+=("cephadm shell -- ceph orch ps --daemon-type mon")

if [ "$APPLY" -eq 0 ]; then
  echo "# Manual add-host commands (run on $ADMIN_NAME as root, one by one):"
  printf '%s\n' "${CMDS[@]}"
  exit 0
fi
need_root
for i in "${!NODE_NAMES[@]}"; do
  [ "$i" -eq 0 ] && continue
  n=${NODE_NAMES[$i]}; ip=${NODE_IPS[$i]}
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$ip" true \
    || die "root ssh to $ip fails; distribute a key first (see printed commands)"
  # shellcheck disable=SC2029  # pubkey intentionally expanded locally
  ssh "root@$ip" "mkdir -p /root/.ssh && grep -qxF '$(cat /etc/ceph/ceph.pub)' /root/.ssh/authorized_keys 2>/dev/null || echo '$(cat /etc/ceph/ceph.pub)' >> /root/.ssh/authorized_keys"
  if ceph_ orch host ls --format json | grep -q "\"hostname\": \"$n\""; then
    log "$n already in cluster"
  else
    ceph_ orch host add "$n" "$ip" --labels mon,mgr
  fi
done
ceph_ orch apply mon --placement="$MON_N label:mon"
ceph_ orch apply mgr --placement="$MGR_N label:mgr"
ceph_ orch host ls
