# progress (checkpoint)

## 2026-10-22 VIP / ingress offline pack
- [x] Pin Tentacle 20.2.4 defaults: haproxy:2.3 / keepalived:2.2.4 (+ digests)
- [x] build/images.list + build-bundle.sh pulls/saves ingress images
- [x] install-node.sh loads/pushes haproxy+keepalived to node1 registry
- [x] bootstrap.sh pins mgr/cephadm/container_image_{haproxy,keepalived}
- [x] offline/setup-ingress-vip.sh (preview default, --apply)
- [x] cluster.conf.example VIP placeholders; runbook §9 VIP; README
- [x] Tar + SHA256SUMS rebuilt; Release https://github.com/smallyyh0721/Fast_deploy_ceph/releases/tag/bundle-20.2.4-vip
- [x] Box validation: image load/tag + script syntax + conf dry parse
- [!] Live orch apply ingress / VIP failover NOT run on this box (no cluster)

## Prior
- [x] stage a/b Ceph deploy validated; CephFS intentionally not validated
- [x] Release bundle-20.2.4 kept; CSI is separate (not this repo)
