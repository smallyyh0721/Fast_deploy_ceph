# Validation (box, 2026-10-21, times UTC+8)

## Environment
- Box: Debian 13, 8 vCPU, 16 GB RAM. `/dev/kvm` present but **broken** (nested `kvm_spurious_fault` in `kvm_vm_ioctl_create_vcpu`), so VMs run under **QEMU TCG** (software emulation, slow).
- VMs: official `noble-server-cloudimg-amd64` (clean Ubuntu 24.04), node1 4 GB / node2,3 3 GB, 4 vCPU, 12 GB virtio data disks with serials → `/dev/disk/by-id/virtio-CEPHN<n>D<d>`.
- Network: mgmt NIC = QEMU user-net with `restrict=on` (SSH port-forward only, **no internet / no DNS**, see `evidence/stageB-net.log`: `NO_INTERNET` on all 3); storage NIC `stor0` 10.250.0.1x/24 over a QEMU multicast L2 segment.
- Bundle transferred by scp as `ceph-offline-20.2.4-bundle.tar`.

## Stage a – 1 node, 1 disk: PASSED
- `install-node.sh`: SHA256SUMS verified, offline apt `--no-download` install, chrony, cephadm 20.2.4, registry on 10.250.0.11:5000, push → tags `["v20.2.4"]`, `cephadm check-host` → `Host looks OK` (`evidence/stageA-install2.log`).
- Bugs found & fixed during this stage:
  1. apt `file:` repo + `--no-download` → `E: Internal Error, Pathname to install is not absolute` → debs are now staged into `/var/cache/apt/archives` first.
  2. First bootstrap failed: `lookup init binary: "catatonit" not found` (podman *Recommends*, dropped by `--no-install-recommends`) → `catatonit` added to `packages.list`, bundle rebuilt (227 debs). (`evidence/stageA-bootstrap.log`)
- `bootstrap.sh` OK: fsid `b3fcc57b-cd0c-11f1-b843-525400000001`, `mon: 1 daemons, quorum node1`, `mgr: node1.fryujg(active)`, container_image = `10.250.0.11:5000/ceph/ceph@sha256:35c53fcf…` (`evidence/stageA-bootstrap2.log`).
- `add-osds.sh` preview → `CREATE OSD (wipes vdb)`; with confirm flag → `Created osd(s) 0`; `1 osds: 1 up, 1 in`, `pgs: 1 active+clean`; re-run preview → `skip (already OSD on vdb)` (idempotent).

## Stage b – 3 nodes, 1 disk each: core PASSED, CephFS step not confirmed
Stage b extended the stage-a cluster (node1 re-ran install/bootstrap idempotently); node2/node3 were fresh clean VMs installed from the full rebuilt bundle.
- node2/3 `install-node.sh` OK, `registry 10.250.0.11:5000 reachable, pull OK`, chrony `^* 10.250.0.11 stratum 10` (`evidence/stageB-install{2,3}.log`).
- Host add (pubkey appended to node2/3 `authorized_keys`, then `add-hosts.sh --apply`): 3 hosts `node1 _admin,mon,mgr / node2 mon,mgr / node3 mon,mgr`. Bug fixed: `--apply` precheck now uses `ceph cephadm check-host` (first try wrongly tested node1's own root ssh).
- `ceph mon stat`: `3 mons … quorum 0,1,2 node1,node2,node3`; `ceph mgr stat`: active `node1.fryujg`, `num_standby: 1`.
- OSDs: `Created osd(s) 1 on host 'node2'`, `osd(s) 2 on host 'node3'`; `ceph osd tree`: host node1/node2/node3 each with 1 OSD, all `up`; `3 osds: 3 up, 3 in` (`evidence/stageB-osds.log`).
- `setup-cephfs.sh`: pools models_meta/models_data `size 3 / min_size 2` set, `Scheduled mds.models update...`; **the script then stalled** and final `ceph -s` / `fs status` evidence could not be collected: the box ran out of RAM (MemAvailable ≈ 230 MB, load avg 20) with 3 TCG VMs, so `cephadm shell` calls timed out. MDS active/standby and client mount are therefore **not verified**.

## Stage c – 3 × 4 disks: NOT RUN (by instruction; also not feasible on box RAM under TCG).

## Known gaps
- `.mgr` pool keeps the size it was created with (stage a created it with size 1); on a real fresh 3-node deploy it is created after `osd_pool_default_size=3`? No – bootstrap creates `.mgr` before the default is set → run `ceph osd pool set .mgr size 3` after OSDs (TODO in setup-cephfs.sh).
- `ceph-common` deb is Ubuntu's 19.2.x (client tools only); daemons are 20.2.4 containers.
