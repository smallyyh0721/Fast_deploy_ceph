# Fast_deploy_ceph

Offline (air-gapped) 3-node Ceph Tentacle **20.2.4** toolkit for clean Ubuntu 24.04 x86_64
(cephadm + podman + local registry on node1). Primary use: **RBD**. Production **VIP** via
cephadm ingress (**haproxy + keepalived** container images in the offline pack). CephFS optional.
Ceph CSI is a **separate** offline project — not in this repo.

## S3 VIP + BGP/ECMP（可选，默认关闭）

默认 S3 入口仍是 cephadm ingress VIP（haproxy + keepalived，`RGW_INGRESS=1`），行为不变。
可选的 BGP/ECMP 入口已产品化为纯 shell：`ENABLE_S3_BGP=1` 后 **`sudo ./offline/deploy.sh --only s3-bgp`**
（= `offline/setup-s3-bgp.sh`，回退 `offline/teardown-s3-bgp.sh`），只在 RGW 节点装离线包内的 FRR，
健康时发布 VIP/32。交换机侧人工执行。见 **[docs/s3-bgp.md](docs/s3-bgp.md)**（VIP 与 BGP 对比、边界、回退）、
**[docs/s3-bgp-switch-h3c.md](docs/s3-bgp-switch-h3c.md)**（H3C 应用/检查/回退）。
实验依据与证据：[doc/s3-vip-bgp-20261027/README.md](doc/s3-vip-bgp-20261027/README.md)。

## Existing offline toolkit

- `build/` — internet machine: `./build/build-bundle.sh` → bundle + tar + `SHA256SUMS`
  - `images.list` pins `ceph`, `registry:2`, `haproxy:2.3`, `keepalived:2.2.4`
- **One-click:** `sudo ./offline/deploy.sh --dry-run` then `sudo ./offline/deploy.sh` on node1 —
  validate → install (pushed over SSH) → bootstrap → hosts → OSD preview + **typed confirm** → OSD →
  RBD pools → RGW (+ own ingress VIP) → CephFS → mon VIP → verify. See `docs/oneclick.md`.
- `offline/` — air-gapped nodes (`cluster.conf.example` → `cluster.conf`), step-by-step scripts:
  1. `install-node.sh` (every node, node1 first) — pushes ceph + ingress images to local registry
  2. `bootstrap.sh` (node1) — also pins `mgr/cephadm/container_image_{haproxy,keepalived}`
  3. `add-hosts.sh` / `add-osds.sh`
  4. `setup-ingress-vip.sh` — preview default; `--apply` for VIP (placeholders in conf)
  5. `setup-cephfs.sh` (optional)
  6. new: `validate.sh`, `disk-safety.sh` (+ `tests/`), `setup-pools.sh`, `setup-rgw.sh`, `verify.sh`, `deploy.sh`
  7. optional: `setup-s3-bgp.sh` / `teardown-s3-bgp.sh` + `s3-bgp/` (FRR only on RGW nodes; `build/packages-s3-bgp.list`)
- `docs/oneclick.md` — 一键部署（阶段、续跑、OSD 安全闸门、RGW VIP、可选 `--only s3-bgp`）
- `docs/s3-bgp.md` / `docs/s3-bgp-switch-h3c.md` — 可选 S3 BGP/ECMP 入口（节点侧 / 交换机人工）
- `docs/runbook-3node.md` — 现场手册（hosts / SSH / OSD / **VIP**）
- `docs/cephfs-client.md` — CephFS（可选）
- `docs/validation.md` — 验证记录

Releases:
- [bundle-20.2.4](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4) (baseline)
- [bundle-20.2.4-vip](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-vip) (adds ingress images)
- [bundle-20.2.4-oneclick.1](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-oneclick.1) (**latest**: same debs/images/bin as -vip; offline/ fixes for `bash -s` probe + OSD plan stdin; one-click `deploy.sh`)
- [bundle-20.2.4-oneclick](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-oneclick) (initial one-click; superseded by .1)
