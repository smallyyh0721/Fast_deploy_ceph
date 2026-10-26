# Fast_deploy_ceph

Offline (air-gapped) 3-node Ceph Tentacle **20.2.4** toolkit for clean Ubuntu 24.04 x86_64
(cephadm + podman + local registry on node1). Primary use: **RBD**. Production **VIP** via
cephadm ingress (**haproxy + keepalived** container images in the offline pack). CephFS optional.
Ceph CSI is a **separate** offline project — not in this repo.

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
- `docs/oneclick.md` — 一键部署（阶段、续跑、OSD 安全闸门、RGW VIP）
- `docs/runbook-3node.md` — 现场手册（hosts / SSH / OSD / **VIP**）
- `docs/cephfs-client.md` — CephFS（可选）
- `docs/validation.md` — 验证记录

Releases:
- [bundle-20.2.4](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4) (baseline)
- [bundle-20.2.4-vip](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-vip) (adds ingress images)
- [bundle-20.2.4-oneclick.1](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-oneclick.1) (**latest**: same debs/images/bin as -vip; offline/ fixes for `bash -s` probe + OSD plan stdin; one-click `deploy.sh`)
- [bundle-20.2.4-oneclick](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-oneclick) (initial one-click; superseded by .1)
