# 一键部署 `deploy.sh`

在 **node1（NODE_NAMES[0]）** 以 root 执行；其余节点由 node1 经 root SSH 推送执行。

## 前提（validate 阶段会检查）
- 每个节点：离线包已解压到同一 `BUNDLE_DIR`（`debs/ images/ bin/cephadm images/ceph-v*.tar`）。
- node1 → 各节点 root SSH 免密（BatchMode），`hostname -s` = `NODE_NAMES`，`/etc/hosts` 解析正确。
  默认 `StrictHostKeyChecking=accept-new`。若要求只认已钉扎主机密钥：`SSH_STRICT_HOSTKEY=1` + `SSH_KNOWN_HOSTS=/path/to/known_hosts`（用 `ssh-keyscan` 生成；见 `cluster.conf.example` 与 runbook §3）。远程调用走 `ssh -n`（stdin 关闭）；盘探测是 scp `disk-safety.sh` 后按路径执行，不再 `bash -s` 灌脚本。
- NTP/chrony 视为现场已就绪：**不改写、不检查**（`MANAGE_CHRONY=0`；设 1 恢复旧行为）。
- 若用 git 新版 `offline/` 覆盖了包内脚本：install 阶段用 `install-node.sh --verify-payload`，只校验 `debs/ images/ bin/` 的 SHA256，不受脚本变更影响。

## 用法
```bash
cd /opt/ceph-offline/offline
sudo cp cluster.conf.example cluster.conf && sudo vi cluster.conf   # 旧 cluster.conf 可直接用，新字段有默认值
sudo ./deploy.sh --dry-run          # 只打印每阶段要做的事（不需 root、不连节点）
sudo ./deploy.sh                    # 全流程；中断后再次执行会跳过已完成阶段
sudo ./deploy.sh --from pools       # 从某阶段重做
sudo ./deploy.sh --only verify      # 只跑一个阶段
sudo ./deploy.sh --reset-stage rgw  # 清除阶段标记
sudo ./deploy.sh --list             # 查看阶段标记
```
`--yes` 只跳过开头的 “Start deployment?”，**不会**跳过 OSD 键入确认。
标记：`/var/lib/fast-deploy/<stage>.done`（含 cluster.conf sha256；配置变化会告警）。

## 阶段
| # | 阶段 | 内容 |
|---|---|---|
| 00 | validate | `validate.sh`：数组/IP/网段、by-id 盘、size≤OSD 主机数、pg 为 2 的幂、PG/OSD 预算、RGW/MDS 主机、RGW VIP；远端：SSH、hostname、/etc/hosts、离线包、盘存在、VIP 未占用。无 NTP 检查 |
| 01 | install | node1 本地 → 其它节点：scp `offline/*.sh` + cluster.conf 到 `$BUNDLE_DIR/offline`，ssh 执行 `install-node.sh --verify-payload` |
| 02 | bootstrap | `bootstrap.sh` |
| 03 | hosts | `add-hosts.sh --apply`：自动把 `/etc/ceph/ceph.pub` 追加到各节点 root authorized_keys，加主机、mon/mgr 编排、rgw/mds 标签 |
| 04 | osd-preview | `add-osds.sh --confirm`：安全表 + **人工键入确认**，写 `/var/lib/fast-deploy/osd-plan.txt` |
| 05 | osd | `add-osds.sh --apply-plan`：重新探测，任何变化即拒绝；只 zap 已确认的盘；逐盘 `ceph orch daemon add osd host:/dev/disk/by-id/...`（数据/WAL/DB 同盘）；等待 OSD up |
| 06 | pools | `setup-pools.sh`：.mgr size 对齐，`RBD_POOLS` 创建/size/autoscale/target_ratio/`rbd pool init` |
| 07 | rgw | `setup-rgw.sh`（`ENABLE_RGW=1`）：realm/zonegroup/zone、`orch apply rgw`；`RGW_INGRESS=1` 时 cephadm ingress（haproxy+keepalived）独立 VIP `RGW_VIP` |
| 08 | cephfs | `setup-cephfs.sh`（`ENABLE_CEPHFS=1`，`MDS_HOSTS` 定位） |
| 09 | vip | `setup-ingress-vip.sh --apply`（`ENABLE_MON_VIP=1`） |
| 10 | verify | `verify.sh`：ceph -s / health / osd tree / pools / orch ps / RGW curl / fs status + 汇总（`ENABLE_S3_BGP=1` 时另报每台 BGP 节点状态） |
| — | s3-bgp | **可选，不在默认流程和 `--from` 内**，只能 `./deploy.sh --only s3-bgp`（需 `ENABLE_S3_BGP=1`）：`setup-s3-bgp.sh`，见 [s3-bgp.md](s3-bgp.md) |

## OSD 安全闸门（不可绕过）
`disk-safety.sh` 在每台 OSD 主机上采集 `lsblk -J`、`pvs`、`lvs`、`findmnt`、`/proc/swaps`、`wipefs -n`，逐盘给出：

- **REFUSE**（任何参数都不能覆盖）：非 `/dev/disk/by-id/` 路径、分区路径、解析不到；根盘及 `/boot`、`/boot/efi`、swap 所在盘（经 `lsblk -s` 穿透 LVM/md/dm-crypt 回溯到物理盘）；盘或任一子设备有挂载点；md 成员；swap；LUKS；非 Ceph LVM；其它/未知 Ceph 集群的 LVM；同一物理盘重复。
- **SKIP**：已是本集群（fsid 相符）的 OSD。
- **NEEDS-ZAP**：有旧分区/文件系统签名但未使用。
- **CREATE**：干净盘。

有 REFUSE 默认整体中止（`add-osds.sh --skip-refused` 可跳过这些盘，但它们永远不会被动）。然后必须在终端键入 `YES-WIPE-<N>`（N=CREATE+NEEDS-ZAP 数），并对每块 NEEDS-ZAP 盘键入其序列号后 4 位。绝不使用 `--all-available-devices`；不支持单独 WAL/DB。

单测：`offline/tests/test-disk-safety.sh`（mock lsblk 快照，含根盘在 LVM、根在 md RAID1）。

## RGW 独立 VIP
```bash
ENABLE_RGW=1; RGW_HOSTS=(node2 node3); RGW_PORT=8080
RGW_INGRESS=1; RGW_VIP="10.250.0.20"; RGW_VIP_CIDR=24; RGW_FRONTEND_PORT=80
```
S3 入口 `http://RGW_VIP:RGW_FRONTEND_PORT`；haproxy/keepalived 镜像来自 node1 本地 registry（离线包已含）。keepalived `first_virtual_router_id=RGW_VRRP_ROUTER_ID`（默认 60，与 mon VIP 的 50 区分）。
用户：`cephadm shell -- radosgw-admin user create --uid=app --display-name=app`。

## 可选：S3 BGP/ECMP 入口
在 RGW VIP 正常后，`cluster.conf` 设 `ENABLE_S3_BGP=1`、`S3_BGP_PEER_IP`、`S3_BGP_PEER_ASN`（其余见 example 末尾），然后：
```bash
sudo ./validate.sh
sudo ./deploy.sh --dry-run --only s3-bgp     # 打印每台 frr.conf / sysctl / 动作
sudo ./deploy.sh --only s3-bgp               # 或 ./setup-s3-bgp.sh [--host node2]
# 交换机人工：docs/s3-bgp-switch-h3c.md
sudo ./verify.sh                              # 每台 LOCAL-OK / PENDING-SWITCH / ...
sudo ./teardown-s3-bgp.sh                     # 回退（先回退交换机）
```
`ENABLE_S3_BGP=0`（默认）时默认流程与 oneclick.1 逐行一致；VIP（keepalived/haproxy）在两种模式下都保持不变。

## 旧用法
分步脚本 `install-node.sh / bootstrap.sh / add-hosts.sh / add-osds.sh / setup-*.sh` 仍可单独使用（`add-osds.sh --yes-i-really-mean-it` 现在也要求同样的键入确认）。
