# 一键式 Ceph 部署测试（2026-10-26）

包：`bundle-20.2.4-oneclick.1`，`ceph-offline-20.2.4-oneclick.1-bundle.tar`。sha256 `c90132aedc8474ad014c3dd3481fe5d3c4777eaff912087af09b4cfff3937697`。脚本是 main@fd28d26，已包含先前两处修复。这次没有改脚本，也没有新的脚本故障，所以没有开 GitHub issue。

下次说「一键式ceph部署测试」时按 skill `ceph-oneclick-test` 做。集群已在跑时只复查，不重新清盘。

## 前置

三台虚拟机：`nettest-40/41/42` = `10.11.4.40/41/42`。从 `10.11.4.22` 用 `~/.ssh/vm-cluster` 登录 `ubuntu`。

- `/etc/hosts` 三台相同，`getent` 返回这三台的 10.11.4 地址，不是 `127.0.1.1`。`/etc/cloud/cloud.cfg.d/99-lab-hosts.cfg` 里 `manage_etc_hosts: false`。
- `nettest-40` 的 root 对 `.41`、`.42` 的 root 免密。`PermitRootLogin without-password`。
- 三台都解压到 `/opt/ceph-offline`，并删掉了家目录里的 tar，避免占满 19G 系统盘。

## cluster.conf

相对包内 example，只改了这些项。完整文件在三台的 `/opt/ceph-offline/offline/cluster.conf`。

| 项 | 值 |
|---|---|
| NODE_NAMES / NODE_IPS | nettest-40/41/42 = 10.11.4.40/41/42 |
| PUBLIC_NETWORK | 10.11.4.0/24 |
| OSD_DEVICES | 12 块：`virtio-NT40D1`–`D4`、`NT41D1`–`D4`、`NT42D1`–`D4` |
| OSD_MEMORY_TARGET | 939524096 |
| RBD_POOLS | `rbd:64:3:` |
| ENABLE_RGW | 1，`RGW_HOSTS=(nettest-41 nettest-42)`，端口 8080 |
| RGW_INGRESS / RGW_VIP | 1，`10.11.4.50/24`，前端 80，VRRP id 60 |
| ENABLE_MON_VIP | 0。占位 `VIP_ADDR=10.11.4.49`，没有落地 |
| ENABLE_CEPHFS / MANAGE_CHRONY | 0 / 0 |

## 命令

在 nettest-40 上：

```bash
cd /opt/ceph-offline/offline
sudo ./deploy.sh --dry-run
sudo ./validate.sh
sudo ./deploy.sh --yes
```

`validate.sh` 全部 ok，包括 12 块盘存在、VIP `10.11.4.50` 空闲。正式部署由 TTY 驱动，OSD 预览是 12 个 CREATE、0 个 REFUSE，输入了 `YES-WIPE-12`。

## 结果

`verify: OK`。fsid `16c96e91-d119-11f1-9c37-021104000028`。

- mon 3 个在仲裁，leader nettest-40；mgr 在 nettest-40，standby nettest-41
- OSD 12 up / 12 in；257 PG 全部 active+clean
- 池 7 个，含 `rbd` 和 `default.rgw.buckets.data`
- RGW 在 nettest-41、nettest-42 的 8080；haproxy 和 keepalived 各 2 个
- VIP `10.11.4.50/24` 在 nettest-41 的 `enp1s0` 上
- 从 10.11.4.22 访问 `http://10.11.4.50/` 返回 `ListAllMyBucketsResult`

健康是 `HEALTH_WARN`，只有 mon.nettest-41 时钟慢约 0.40 秒。`MANAGE_CHRONY=0`，脚本没有改 NTP。这不是脚本失败。

## S3

用户 `s3test`，桶 `nettest`。密钥在 `.secrets/s3test.txt`，不写入这份说明。

```text
endpoint   http://10.11.4.50
bucket     nettest
uid        s3test
```

签名访问 `GET /` 能列出桶 `nettest`。匿名访问根路径也会返回空的 ListAllMyBuckets，这是当前 RGW 的匿名行为。
