# Fast_deploy_ceph

Offline (air-gapped) 3-node Ceph Tentacle 20.2.4 toolkit for clean Ubuntu 24.04 x86_64
(cephadm + podman + local registry on node1). Primary use: **RBD**; CephFS is optional.

- `build/` — internet machine: `./build/build-bundle.sh` → bundle + tar + `SHA256SUMS`
- `offline/` — air-gapped nodes (`cluster.conf.example` → `cluster.conf`):
  1. `install-node.sh` (every node, node1 first)
  2. `bootstrap.sh` (node1)
  3. `add-hosts.sh` (prints host-add commands; needs root SSH + `ceph.pub`)
  4. `add-osds.sh` (preview, then `--yes-i-really-mean-it`)
  5. `setup-cephfs.sh` (optional; see docs)
- `docs/runbook-3node.md` — **现场操作手册**（hosts / SSH 免密 / 安装到 OSD）
- `docs/cephfs-client.md` — CephFS + 客户端挂载（可选）
- `docs/validation.md` — 验证记录

Release asset: [bundle-20.2.4](https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4).
