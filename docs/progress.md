# progress (checkpoint)
- [x] bundle built: /workspace/Fast_deploy_ceph-bundle (1.6G, 226 debs, ceph+registry tars, cephadm 20.2.4, SHA256SUMS)
- [x] build/ + offline/ scripts written, shellcheck clean; docs/runbook-3node.md
- [x] /dev/kvm broken (nested kvm_spurious_fault on vcpu create) -> using QEMU TCG
- [ ] stage a VM node1 (TCG, /workspace/vm, ssh -p 2221 -i /workspace/vm/id root@127.0.0.1)
- [x] stage a: offline install-node.sh OK in no-internet TCG VM (fix: stage debs in apt cache for --no-download) log vm/stageA-install2.log
- [!] bootstrap failed: catatonit missing (podman Recommends). Added to packages.list, rebuilding bundle
- [x] stage a bootstrap OK (fsid b3fcc57b..., container_image=10.250.0.11:5000 digest) vm/stageA-bootstrap2.log
- [x] stage a: 1 OSD up, HEALTH active+clean, vm/stageA-osd.log
