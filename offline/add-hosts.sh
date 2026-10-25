#!/usr/bin/env bash
# Run on node1. Default: PRINT the manual add-host commands for nodes 2..N.
#   ./add-hosts.sh            # print commands only (recommended: run them by hand)
#   ./add-hosts.sh --apply    # execute them: also appends /etc/ceph/ceph.pub to each peer's
#                             # root authorized_keys over the existing root ssh (BatchMode),
#                             # and adds labels rgw (RGW_HOSTS) / mds (MDS_HOSTS)
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
  # distribute cephadm's key over the already-working root ssh (node1 -> peers)
  if [ -s /etc/ceph/ceph.pub ]; then
    ssh_node "$ip" "install -d -m 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && (grep -qxF '$(cat /etc/ceph/ceph.pub)' /root/.ssh/authorized_keys || echo '$(cat /etc/ceph/ceph.pub)' >> /root/.ssh/authorized_keys)" \
      || warn "could not push ceph.pub to $n over root ssh; append it by hand"
  fi
  ceph_ cephadm check-host "$n" "$ip" \
    || die "cephadm cannot reach $n ($ip) as root with /etc/ceph/ceph.pub; distribute the key first"
  if ceph_ orch host ls --format json | grep -q "\"hostname\": \"$n\""; then
    log "$n already in cluster"
  else
    ceph_ orch host add "$n" "$ip" --labels mon,mgr
  fi
done
ceph_ orch apply mon --placement="$MON_N label:mon"
ceph_ orch apply mgr --placement="$MGR_N label:mgr"
if [ "$ENABLE_RGW" = 1 ]; then for h in "${RGW_HOSTS[@]}"; do ceph_ orch host label add "$h" rgw >/dev/null; done; fi
if [ "$ENABLE_CEPHFS" = 1 ]; then for h in "${MDS_HOSTS[@]}"; do ceph_ orch host label add "$h" mds >/dev/null; done; fi
ceph_ orch host ls
