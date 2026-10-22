# Validation notes

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
