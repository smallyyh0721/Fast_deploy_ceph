# Fast_deploy_ceph

Offline (air-gapped) 3-node Ceph Tentacle 20.2.4 deployment toolkit for clean Ubuntu 24.04 x86_64
(cephadm + podman + local registry on node1).

- `build/` – run on an internet machine: `./build/build-bundle.sh` → `../Fast_deploy_ceph-bundle` + tar + SHA256SUMS
- `offline/` – run on the air-gapped nodes (`cluster.conf.example` → `cluster.conf`):
  1. `install-node.sh` (every node, node1 first) 2. `bootstrap.sh` (node1)
  3. `add-hosts.sh` (prints manual host-add commands) 4. `add-osds.sh` (preview, then `--yes-i-really-mean-it`)
  5. `setup-cephfs.sh`
- `docs/runbook-3node.md` – full runbook (Chinese); `docs/validation.md` – test evidence.
