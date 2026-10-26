# Validation notes

## Live cluster: bundle-20.2.4-oneclick.1 (2026-10-26) — SUCCESS

Release tarball `ceph-offline-20.2.4-oneclick.1-bundle.tar`, sha256 `c90132aedc8474ad014c3dd3481fe5d3c4777eaff912087af09b4cfff3937697`. Scripts were the packaged `offline/` (main@fd28d26). No script edits during the test.

Three Ubuntu 24.04.5 VMs, 4 vCPU / 8 GiB, macvtap on the physical `10.11.4.0/24` VLAN. Each node had four empty 20G virtio disks with stable `/dev/disk/by-id/virtio-NT*` names. S3 VIP `10.11.4.50`. Mon VIP left off.

Commands on node1, after hosts and root SSH were already in place:

```bash
cd /opt/ceph-offline/offline
sudo ./deploy.sh --dry-run
sudo ./validate.sh
sudo ./deploy.sh --yes
```

OSD preview: 12 CREATE, 0 REFUSE. Operator typed `YES-WIPE-12`. `verify: OK`.

- fsid `16c96e91-d119-11f1-9c37-021104000028`
- 3 mons in quorum, mgr active plus one standby
- 12 OSDs up/in, 257 PGs active+clean
- pools include `rbd` and `default.rgw.buckets.data`
- 2 RGW daemons, haproxy and keepalived running; VIP answered `http://10.11.4.50/`
- signed S3 from an external host: list buckets, create bucket `nettest`, put and get `local-test.txt` all HTTP 200

`HEALTH_WARN` only: one mon clock skew about 0.40s. `MANAGE_CHRONY=0`, so the script did not touch NTP. Not a script failure.

## Bundle bundle-20.2.4-vip (2026-10-22, Asia/Shanghai)

Pinned ingress images (Tentacle 20.2.4 `DefaultImages`):
- `quay.io/ceph/haproxy:2.3` digest `sha256:5479ac79e01ff403396e22ccf0e9e3352ab4518e5164105c2aa1879c5ee2f0b5`
- `quay.io/ceph/keepalived:2.2.4` digest `sha256:93f9db46da4915288b75b79f8df41a94cda00e7b50b7413a119036ec70430424`

### Tested on this box
- [x] Images pulled, saved into `images/*.tar`, tagged as `10.250.0.11:5000/ceph/{haproxy,keepalived}:…`
- [x] `bash -n` on build/offline scripts
- [x] `load_conf` resolves VIP placeholders and local registry image refs
- [x] SHA256SUMS regenerated; tar `ceph-offline-20.2.4-vip-bundle.tar` built (~1.9G)

### Not tested here (residual risk)
- Full `ceph orch apply ingress` on a live 3-node cluster (no Ceph cluster running on box now)
- VIP failover / keepalived VRRP on real NICs
- CSI attaching via VIP (CSI is a separate project)
- Stock Tentacle ingress uses **HTTP** haproxy mode for non-nfs backends — mon msgr2 path defaults to `INGRESS_KEEPALIVE_ONLY=1`

## Prior (bundle-20.2.4)
- Stage a (1 node 1 OSD) and stage b (3 nodes 1 OSD each) passed under QEMU TCG; CephFS not validated per Alex.
