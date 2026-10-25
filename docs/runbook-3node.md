# Ceph 3 节点离线部署现场手册

> **适用**：3 × Ubuntu Server 24.04 LTS（x86_64），每台 1 块系统盘 + **4 块数据盘**，网络已配好；无外网、无 DNS。  
> **版本**：Ceph Tentacle **20.2.4**，cephadm + podman，离线包。  
> **目标**：3 MON + 2 MGR + 12 OSD；生产 **VIP**（cephadm ingress：haproxy + keepalived 容器）；默认副本 **size=3 / min_size=2**。首选 **RBD**；CephFS 见 [cephfs-client.md](cephfs-client.md)。CSI 离线包另仓，不在本仓库。  
> **工具**：`build/`（联网机打包）+ `offline/`（现场执行）。示例 IP/主机名以下表为准，按现场改 `cluster.conf`。

> **一键方式**：完成 §2 /etc/hosts、§3.1–3.2 root 免密、§4 各节点解包 + 填 `cluster.conf` 后，node1 执行
> `sudo ./deploy.sh --dry-run` → `sudo ./deploy.sh`（详见 [oneclick.md](oneclick.md)）。§3.3 ceph.pub 由 hosts 阶段自动分发；
> OSD 阶段会停下来要求键入 `YES-WIPE-<N>` 与旧数据盘序列号后 4 位。以下为分步手工流程。

## 0. 参数与步骤

| 项 | 示例 |
|---|---|
| 主机名（=`hostname -s`） | `node1` `node2` `node3` |
| 存储 IP | `10.250.0.11` `.12` `.13`，`PUBLIC_NETWORK=10.250.0.0/24` |
| Registry | 仅 node1：`10.250.0.11:5000`（HTTP） |
| 时间 | 现场 NTP 已就绪；`install-node.sh` 默认不改 chrony（`MANAGE_CHRONY=1` 才让 node1 做 NTP 源） |
| OSD | 每台 4 条 `nodeX:/dev/disk/by-id/...`（严禁系统盘） |
| 副本 | `POOL_SIZE=3` `POOL_MIN_SIZE=2` |
| VIP（占位） | `VIP_ADDR=10.250.0.10`，`VIP_INTERFACE_NETWORK=10.250.0.0/24`（cephadm ingress） |

```text
存储网 10.250.0.0/24
  node1 .11  registry:5000 + MON/MGR + OSD×4（admin）
  node2 .12  + MON/MGR + OSD×4
  node3 .13  + MON     + OSD×4
```

| 阶段 | 地点 | 动作 | 完成条件 |
|---|---|---|---|
| ① 打包 | 联网机 | `build/build-bundle.sh` | tar + `SHA256SUMS` |
| ② 解包 | 3 台 | 解压到 `/opt/ceph-offline`，校验 | `sha256sum -c` 通过 |
| ③ hosts / SSH | 3 台 / node1 | 见 §2、§3 | 主机名互通；node1→node2/3 root 免密 |
| ④ 配置 | 3 台同一份 | `cluster.conf` | IP、主机名、by-id 正确 |
| ⑤ 安装 | **先 node1，再 2/3** | `./install-node.sh` | registry 可拉，`cephadm check-host` OK |
| ⑥ Bootstrap | node1 | `./bootstrap.sh` | 1 MON + 1 MGR |
| ⑦ 加主机 | node1 | 分发 `ceph.pub` + `./add-hosts.sh` | 3 主机、3 MON、2 MGR |
| ⑧ OSD | node1 | `./add-osds.sh` 预览 → 确认执行 | `12 osds: 12 up, 12 in` |
| ⑨ VIP | node1 | 填 `VIP_*` → `./setup-ingress-vip.sh` → `--apply` | VIP 漂移；ingress daemon 在跑 |

---

## 1. 联网机打包

```bash
git clone <repo> Fast_deploy_ceph && cd Fast_deploy_ceph
cp offline/cluster.conf.example offline/cluster.conf   # 可现场再改
OUT=$PWD/../Fast_deploy_ceph-bundle ./build/build-bundle.sh
```

产出 `ceph-offline-20.2.4-bundle.tar`。搬运后核对 tar 的 sha256（Release 附带 `.sha256` 时优先用它）。

---

## 2. `/etc/hosts`（无 DNS，三台都做）

cephadm 按**主机名**登记节点，三台必须互相能解析。无 DNS 时三台写入相同内容（按现场改 IP/名）：

```bash
sudo tee -a /etc/hosts >/dev/null <<'HOSTS'
10.250.0.11  node1
10.250.0.12  node2
10.250.0.13  node3
HOSTS
getent hosts node1 node2 node3
ping -c1 node1; ping -c1 node2; ping -c1 node3
```

- `hostname -s` 必须与上表及 `NODE_NAMES` 一致（不一致先改主机名再继续）。
- 不要依赖 `/etc/resolv.conf` 或外网 DNS。

---

## 3. 节点间 SSH 免密（cephadm 必需）

cephadm 从 **node1 以 root** SSH 到 node2/node3 部署守护进程。现场必须先打通 **node1 → node2/node3 的 root 免密**；bootstrap 之后还要把 **cephadm 公钥**装上。

### 3.1 开通 root 公钥登录（三台）

Ubuntu 默认 `PermitRootLogin prohibit-password`（禁密码、允公钥），一般无需改 sshd。若 `/root/.ssh` 不存在：

```bash
# 每台执行
sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
sudo touch /root/.ssh/authorized_keys && sudo chmod 600 /root/.ssh/authorized_keys
```

### 3.2 从 node1 配置到 node2、node3 的免密

在 **node1**（用已有运维密钥，或新建一把仅用于本集群）：

```bash
# 若尚无密钥
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519

# 把 node1 的 root 公钥装到 node2、node3（有密码时用 ssh-copy-id；否则人工追加）
sudo ssh-copy-id -i /root/.ssh/id_ed25519.pub root@node2
sudo ssh-copy-id -i /root/.ssh/id_ed25519.pub root@node3
# 无密码时：把 /root/.ssh/id_ed25519.pub 内容追加到 node2/3 的 /root/.ssh/authorized_keys
```

验证（必须全部成功，再往下做）：

```bash
sudo ssh -o BatchMode=yes root@node2 hostname -s   # → node2
sudo ssh -o BatchMode=yes root@node3 hostname -s   # → node3
```

建议用上述免密把同一份 `cluster.conf` 和离线包从 node1 `scp` 到 node2/3。

### 3.3 Bootstrap 之后：把免密加到 `ceph.pub`（加主机前必做）

**现场易错点（已踩过）：**

| 情况 | 说明 |
|---|---|
| `sudo ssh node2` 已通，但 `ceph orch host add` 报 `Permission denied` / `Auth failed for user root` | 运维钥（§3.2）已通；cephadm **只用** `/etc/ceph/ceph.pub`，两把钥匙，缺一把就会失败 |
| 在 node2/node3 上执行 `ssh-copy-id -i /etc/ceph/ceph.pub` | 文件不存在。`ceph.pub` **只在 bootstrap 节点（node1）**；命令必须在 **node1** 跑 |
| 在 node2 上跑 `ceph orch host add` | node2 还不是 admin，会报 cluster/conf 找不到。`host add` 只在 **node1** 执行 |

`bootstrap.sh` 在 node1 生成 `/etc/ceph/ceph.pub`。加主机前必须把它装进 node2/node3 的 `root` `authorized_keys`（与 §3.2 运维钥并存，`-f` 追加不覆盖）：

```bash
# ===== 全部在 node1（bootstrap 节点）执行 =====
sudo ls -l /etc/ceph/ceph.pub          # 必须存在；没有则 bootstrap 未完成
sudo cat /etc/ceph/ceph.pub

sudo ssh-copy-id -f -i /etc/ceph/ceph.pub root@node2
sudo ssh-copy-id -f -i /etc/ceph/ceph.pub root@node3
# 或：把 /etc/ceph/ceph.pub 整行追加到 node2/3 的 /root/.ssh/authorized_keys

# 必须用 ceph.pub 这把钥验证（不要只用默认 ssh）
sudo ssh -i /etc/ceph/ceph.pub -o BatchMode=yes -o IdentitiesOnly=yes root@node2 true
sudo ssh -i /etc/ceph/ceph.pub -o BatchMode=yes -o IdentitiesOnly=yes root@node3 true
```

验证通过后再做 §7 `host add`。

---

## 4. 解包、盘检查、配置

**三台**：

```bash
sudo tar -xf ceph-offline-20.2.4-bundle.tar -C /opt
sudo mv /opt/Fast_deploy_ceph-bundle /opt/ceph-offline
cd /opt/ceph-offline && sha256sum -c --quiet SHA256SUMS && echo OK
```

**盘（不擦盘，只核对）**：

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/ | grep -v -- -part
sudo wipefs -n /dev/disk/by-id/<每块数据盘>    # 仅预览
```

- 只把**数据盘** by-id 写入 `OSD_DEVICES`；系统盘禁止出现。
- QEMU virtio 若无 by-id：宿主机给盘加 `serial=`，客机出现 `/dev/disk/by-id/virtio-...`（见验证环境说明）。

**配置**：三台同一份 `cluster.conf`（node1 改好后 `scp`）：

```bash
cd /opt/ceph-offline/offline
sudo cp cluster.conf.example cluster.conf && sudo vi cluster.conf
```

---

## 5. 安装：`install-node.sh`

**先 node1，再 node2、node3**（2/3 会验证能从 node1 registry 拉镜像）：

```bash
cd /opt/ceph-offline/offline && sudo ./install-node.sh
```

脚本会：离线 apt、启用 ssh、（仅 `MANAGE_CHRONY=1` 时才配置 chrony，默认不动 NTP）、装 cephadm、配置 registry 信任；node1 启动 `10.250.0.11:5000` 并推送 **ceph / haproxy / keepalived** 镜像；各节点 `podman load` 兜底。可重复执行。

验收要点：

```bash
# 各节点
sudo cephadm check-host
# node2/3
curl -s http://10.250.0.11:5000/v2/ceph/ceph/tags/list   # 含 v20.2.4
```

Registry 只绑存储网 IP、HTTP 无认证，存储网须为受控内网。

---

## 6. Bootstrap（node1）

```bash
cd /opt/ceph-offline/offline && sudo ./bootstrap.sh
```

等价要点：`cephadm bootstrap --mon-ip <node1存储IP>`，**不用** `--single-host-defaults`；设置 `public_network`、默认 pool size/min_size、给 node1 打 `_admin,mon,mgr`。

期望：1 MON + 1 MGR；无 OSD 时 `HEALTH_WARN` 正常。然后立即做 **§3.3** 分发 `ceph.pub`。

---

## 7. 加主机（仅 node1）

**前置：** §3.3 已用 `/etc/ceph/ceph.pub` 打通 node1→node2/node3；未做会 `Auth failed for user root`。

```bash
./add-hosts.sh                  # 只打印命令（推荐按打印手工执行）
# ./add-hosts.sh --apply        # 已确认 ceph.pub 免密后再用
```

手工顺序：

```bash
sudo cephadm shell -- ceph orch host add node2 10.250.0.12 --labels mon,mgr
sudo cephadm shell -- ceph orch host add node3 10.250.0.13 --labels mon,mgr
sudo cephadm shell -- ceph orch apply mon --placement="3 label:mon"
sudo cephadm shell -- ceph orch apply mgr --placement="2 label:mgr"
sudo cephadm shell -- ceph orch host ls
sudo cephadm shell -- ceph quorum_status -f json-pretty | grep -A4 quorum_names
```

合格：3 主机非 Offline；`quorum node1,node2,node3`；1 MGR active + 1 standby。

可选：`ceph orch host label add node2 _admin`，同步管理配置到 node2。

---

## 8. OSD：`add-osds.sh`

```bash
sudo cephadm shell -- ceph orch device ls --wide --refresh
sudo ./add-osds.sh                              # 预览：CREATE / NEEDS-ZAP / SKIP / REFUSE 安全表
sudo ./add-osds.sh --confirm                    # 键入 YES-WIPE-<N> + 旧数据盘序列号后4位 → 写计划
sudo ./add-osds.sh --apply-plan /var/lib/fast-deploy/osd-plan.txt   # 复核后按计划 zap+创建
# 旧用法 --yes-i-really-mean-it 仍可用，但同样要求键入确认
```

- 根盘/boot/EFI/swap 所在盘（含根在 LVM/md 上）、已挂载、md 成员、非 Ceph LVM、非 by-id 路径一律 REFUSE，不可绕过。
- OSD 数据/WAL/DB 同盘，不单独放 DB。

- **严禁** `ceph orch apply osd --all-available-devices`。
- 已是 OSD 的盘会跳过；有旧签名时人工确认后再 `ceph orch device zap ... --force`。

验收：`ceph osd tree` 每 host 4 个 OSD；`ceph osd stat` → `12 osds: 12 up, 12 in`。


---

## 9. 生产 VIP（cephadm ingress）

离线包含 Tentacle 默认镜像：`quay.io/ceph/haproxy:2.3`、`quay.io/ceph/keepalived:2.2.4`（`install-node.sh` 已推到 node1 registry，并在 bootstrap 时写入 `mgr/cephadm/container_image_*`）。

### 9.1 填占位

编辑三台同一份 `cluster.conf`：

```bash
VIP_ADDR="10.250.0.10"                 # 现场实 IP
VIP_CIDR="24"
VIP_INTERFACE_NETWORK="10.250.0.0/24"   # 用于选网卡，通常 = PUBLIC_NETWORK
INGRESS_BACKEND_SERVICE="mon"
INGRESS_SERVICE_ID="mon"
INGRESS_KEEPALIVE_ONLY=1               # mon/CSI 推荐 1；RGW/NFS 全量 haproxy 时改 0
```

### 9.2 预览 → 应用（仅 node1）

```bash
cd /opt/ceph-offline/offline
sudo ./setup-ingress-vip.sh                 # 只打印 YAML 与将执行的命令
sudo ./setup-ingress-vip.sh --apply         # 钉镜像 + ceph orch apply ingress
```

验收：

```bash
sudo cephadm shell -- ceph orch ls ingress
sudo cephadm shell -- ceph orch ps --service-name ingress.mon
# 各节点看 VIP 落在哪台：
ip -br addr | grep 10.250.0.10 || true
```

### 9.3 与后续 CSI / CephX

- **CSI monitors（另仓离线包）**：优先写 **全部 MON IP:3300**；VIP 仅在确认可达后再加为额外入口。`INGRESS_KEEPALIVE_ONLY=1` 时 VIP 随 keepalived 漂移，**不会**自动让 mon 监听在 VIP 上。
- Tentacle 对非 NFS 的 ingress 默认 **haproxy HTTP 模式**，不适合直接扛 MON msgr2；故本手册 mon VIP 默认 `keepalive_only`。全量 haproxy+keepalived 留给 RGW/NFS（`INGRESS_KEEPALIVE_ONLY=0` + 改 `INGRESS_BACKEND_SERVICE`）。
- **CephX**：只需 keyring / K8s Secret，**无镜像**。

集群至此可用于 **RBD**。CephFS 见 [cephfs-client.md](cephfs-client.md)。

---

## 10. 验收清单

以下命令均在 **node1** 执行。统一用 `cephadm shell`（宿主机直接 `ceph -s` 可能因旧版 `ceph-common` / keyring 报错，不代表集群异常）。

### 10.1 集群监控（健康 / MON / MGR）

```bash
sudo cephadm shell -- ceph -s
sudo cephadm shell -- ceph health detail
sudo cephadm shell -- ceph orch host ls
sudo cephadm shell -- ceph orch ps
sudo cephadm shell -- ceph quorum_status -f json-pretty | grep -A6 quorum_names
sudo cephadm shell -- ceph mgr stat
```

| 看什么 | 合格 |
|---|---|
| `ceph -s` | `health: HEALTH_OK`（无 OSD/无 pool 时可为 `HEALTH_WARN`，属中间态） |
| `health detail` | 无 `MON_CLOCK_SKEW`；无持续 `OSD_DOWN` / `PG_DEGRADED`（上线后） |
| `orch host ls` | 3 主机，无 Offline |
| `quorum_names` | 3 个 MON 均在 quorum |
| `mgr stat` | 1 active + ≥1 standby |

### 10.2 OSD 状态

```bash
sudo cephadm shell -- ceph osd stat
sudo cephadm shell -- ceph osd tree
sudo cephadm shell -- ceph osd df tree
sudo cephadm shell -- ceph orch device ls --wide
sudo cephadm shell -- ceph pg stat
# 有 pool 之后再看：
sudo cephadm shell -- ceph osd pool ls detail
```

| 看什么 | 合格（本手册默认 3×4 盘） |
|---|---|
| `osd stat` | `12 osds: 12 up, 12 in` |
| `osd tree` | 每个 host 下 4 个 OSD，`up` / `in`（weight > 0） |
| `osd df tree` | 无异常近满盘；三台用量大致均衡 |
| `device ls` | 数据盘已用或 Available 与规划一致；系统盘未进 OSD |
| `pg stat` | 有 pool 后 PG 均为 `active+clean`（或短暂 `peering` 后收敛） |
| `pool ls detail` | `size 3` `min_size 2`（或与 `cluster.conf` 一致） |

### 10.3 总表

| 项 | 合格 |
|---|---|
| hosts / 主机名 | 三台 `getent hosts` 与 `hostname -s` 一致 |
| SSH | node1 `BatchMode` root → node2/node3；`ceph.pub` 同样可登录 |
| 时间 | 无 `MON_CLOCK_SKEW` |
| Registry | node2/3 能 pull `10.250.0.11:5000/ceph/ceph:v20.2.4` |
| MON / MGR | 见 §10.1 |
| OSD | 见 §10.2 |
| 副本 | 默认 size 3 / min_size 2 |
| VIP / ingress | `orch ls ingress` 有服务；`keepalive`/`haproxy` 按配置在跑；VIP 在某一节点 |
| 故障 | 关一台非全部中断；恢复后回到 clean |

## 11. 上线前确认

- [ ] `/etc/hosts` 三台一致；无 DNS 依赖
- [ ] node1→node2/3 root 免密；`/etc/ceph/ceph.pub` 已装到 node2/3
- [ ] 12 块数据盘 by-id 已核对；系统盘不在 `OSD_DEVICES`
- [ ] 三台 `install-node.sh` 成功；registry 开机自启
- [ ] 3 MON / 2 MGR / 12 OSD 正常
- [ ] VIP 已填实地址并 `setup-ingress-vip.sh --apply`（或明确暂缓）
- [ ] 备份：`/etc/ceph/*`、`cluster.conf`、registry 数据、离线包
