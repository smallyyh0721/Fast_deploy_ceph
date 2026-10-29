# CephFS 与客户端挂载（可选）

> 主路径以 **RBD** 为准，见 [runbook-3node.md](runbook-3node.md)。仅在需要文件系统接口时使用本文。  
> 前置：3 MON / 2 MGR / OSD 已 up，PG 健康；在 **node1** 执行。

## 1. 创建 CephFS：`setup-cephfs.sh`

```bash
cd /opt/ceph-offline/offline && sudo ./setup-cephfs.sh
```

等价（均通过 `sudo cephadm shell -- ceph ...`）：

```bash
ceph osd pool create models_meta 32
ceph osd pool create models_data 128
ceph osd pool set models_meta size 3 ;  ceph osd pool set models_meta min_size 2
ceph osd pool set models_data size 3 ;  ceph osd pool set models_data min_size 2
ceph fs new models models_meta models_data
ceph orch apply mds models --placement=2        # 1 active + 1 standby
ceph fs set models max_mds 1
ceph fs authorize models client.modelreader / r
ceph fs authorize models client.modelwriter / rw
ceph auth get-key client.modelreader > /root/ceph-client-secrets/modelreader.secret
```

- 名称/PG/客户端账号以 `cluster.conf` 中 `FS_NAME`、`META_*`、`DATA_*`、`CLIENT_*` 为准。
- PG 为 12 OSD 起点值，pg_autoscaler 会调整。
- **不推荐** `min_size=1`（坏一台后只剩单副本）。
- 验收：`ceph fs status models` → 1 active + 1 standby；两 pool `size 3 min_size 2`；`ceph -s` PG `active+clean`。

脚本会把 bootstrap 早于默认副本配置创建的 `.mgr` pool 对齐到 `POOL_SIZE` / `POOL_MIN_SIZE`。

## 2. 客户端挂载

用 `ceph-fuse`。Ubuntu 24.04 内核 6.8 上 `mount -t ceph` 会在写入内核密钥时失败，dmesg 为 `libceph: secret too big 32`。三个 MON 都写上，单台宕机仍可挂。密钥文件是 `ceph auth get-key` 的原文，模式 600。

```bash
sudo mkdir -p /mnt/models
sudo ceph-fuse -n client.modelreader \
  --keyfile /root/ceph-client-secrets/modelreader.secret \
  -m 10.250.0.11:3300,10.250.0.12:3300,10.250.0.13:3300 \
  --client_fs models /mnt/models
```

- 离线节点用 bundle 里的 `ceph-fuse` 和 `libfuse2t64`。节点若已安装 `fuse3`，不要强行配置会冲突的过渡包 `fuse`；`fusermount` 指向 `fusermount3` 即可。
- 只读账号写文件应被拒绝；不要把 admin keyring 发给客户端。
- 常用端口：3300/6789 MON，6800–7568 OSD/MDS，22 SSH；5000 仅 node1↔node2/3（registry）。

## 3. 相关验收

| 项 | 合格 |
|---|---|
| MDS | `ceph fs status`：1 active + 1 standby |
| 切换 | `ceph mds fail models:0` 后 standby 接管 |
| 挂载 | 读正常；只读 key 写失败 |
| 主机故障 | 关一台后客户端仍可读写（degraded），恢复后 clean |
