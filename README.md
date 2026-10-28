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

## 监控 / Dashboard / 宿主机 Ceph 包 / 备份（oneclick.3）

- 监控栈默认部署：`deploy.sh` 阶段 `monitoring`（老集群 `--only monitoring`）— prometheus v3.6.0、alertmanager v0.28.1、
  node-exporter v1.9.1、grafana 12.3.1、ceph-exporter（复用 ceph 镜像），全部来自本地 registry；Dashboard HTTPS 8443。
  告警只导出指标（不配 webhook/SMTP），外部采集端口与示例见 **[docs/monitoring.md](docs/monitoring.md)**。
- 宿主机 `ceph-common` / `librados2` / `librbd1` / `python3-ceph-*` 统一 20.2.4（download.ceph.com `debian-20.2.4` noble，固定版本）。
- `offline/backup-cluster-meta.sh`：只读导出集群元数据，**默认不运行**、不装定时任务，见 **[docs/backup.md](docs/backup.md)**。

## Existing offline toolkit

- `build/` — internet machine: `./build/build-bundle.sh` → bundle + tar + `SHA256SUMS`
  - `images.list` pins `ceph`, `registry:2`, `haproxy:2.3`, `keepalived:2.2.4`, `prometheus`, `alertmanager`, `node-exporter`, `grafana`
  - tars > 2 GiB are split for GitHub (`*.part-NN`; `cat *.part-* > bundle.tar && sha256sum -c bundle.tar.sha256`)
- **One-click:** `sudo ./offline/deploy.sh --dry-run` then `sudo ./offline/deploy.sh` on node1 —
  validate → install (pushed over SSH) → bootstrap → hosts → OSD preview + **typed confirm** → OSD →
  RBD pools → RGW (+ own ingress VIP) → CephFS → mon VIP → monitoring/dashboard → verify. See `docs/oneclick.md`.
- `offline/` — air-gapped nodes (`cluster.conf.example` → `cluster.conf`), step-by-step scripts:
  1. `install-node.sh` (every node, node1 first) — pushes every `images.list` image to the local registry
  2. `bootstrap.sh` (node1) — also pins `mgr/cephadm/container_image_{haproxy,keepalived,prometheus,alertmanager,node_exporter,grafana}`
  3. `add-hosts.sh` / `add-osds.sh`
  4. `setup-ingress-vip.sh` — preview default; `--apply` for VIP (placeholders in conf)
  5. `setup-cephfs.sh` (optional)
  6. new: `validate.sh`, `disk-safety.sh` (+ `tests/`), `setup-pools.sh`, `setup-rgw.sh`, `verify.sh`, `deploy.sh`
  7. `setup-monitoring.sh` (default on) / `backup-cluster-meta.sh` (manual only)
  8. optional: `setup-s3-bgp.sh` / `teardown-s3-bgp.sh` + `s3-bgp/` (FRR only on RGW nodes; `build/packages-s3-bgp.list`)
- `docs/oneclick.md` — 一键部署（阶段、续跑、OSD 安全闸门、RGW VIP、可选 `--only s3-bgp`）
- `docs/s3-bgp.md` / `docs/s3-bgp-switch-h3c.md` — 可选 S3 BGP/ECMP 入口（节点侧 / 交换机人工）
- `docs/runbook-3node.md` — 现场手册（hosts / SSH / OSD / **VIP**）
- `docs/cephfs-client.md` — CephFS（可选）
- `docs/validation.md` — 验证记录

Releases:
- [bundle-20.2.4](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4) (baseline)
- [bundle-20.2.4-vip](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-vip) (adds ingress images)
- [bundle-20.2.4-oneclick.3](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-oneclick.3) (**latest**: monitoring + dashboard by default, host ceph debs 20.2.4, metadata backup; 2 parts `cat *.part-* > bundle.tar`, tar sha256 `b7d1d81730f9d4a995b13b60f5e5284cdc019f5542f56d57063784639b7ce3ee`)
- [bundle-20.2.4-oneclick.2](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-oneclick.2) (oneclick.1 + FRR closure debs; optional S3 BGP/ECMP `deploy.sh --only s3-bgp`, default off and identical to .1)
- [bundle-20.2.4-oneclick.1](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-oneclick.1) (same debs/images/bin as -vip; offline/ fixes for `bash -s` probe + OSD plan stdin; one-click `deploy.sh`)
- [bundle-20.2.4-oneclick](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-oneclick) (initial one-click; superseded by .1)
