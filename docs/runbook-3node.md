# Ceph 3 节点离线部署实施手册（v2.0，基于单节点 v1.0 改写）

> **适用**：3 × Ubuntu Server 24.04 LTS（x86_64 / amd64，纯净安装），每台 1 块系统盘 + **4 块数据盘**，网络（bond0 等）已配置好；Ceph Tentacle **20.2.4**，cephadm + podman，离线。
> **目标**：3 MON + 2 MGR + MDS（1 active + 1 standby）+ 12 OSD，提供 CephFS；副本数可配，默认 **size=3 / min_size=2**（任意坏一台主机不丢数据、不停服）。
> **工具**：本仓库 `build/`（联网机打包）+ `offline/`（离线节点执行）。每一步都给出脚本和等价手工命令。
> 与 v1.0 相同的内容（交换机 LACP、netplan bond、fio、客户端 K8s 接入、运维排障）仍以 v1.0 第 2、8、9、10 节为准，本文只写差异和新增部分。

## 0. 结论与变化点

| 项 | 单节点 v1.0 | 3 节点 v2.0 |
|---|---|---|
| Registry | node 本机 `127.0.0.1:5000` | **只在 node1**，绑定 node1 存储 IP `10.250.0.11:5000`，HTTP；三台都把它配置为 insecure 信任 |
| 镜像兜底 | — | 每台也 `podman load` 主镜像并打上 registry 同名 tag（`LOAD_IMAGE_ON_ALL_NODES=1`），registry 短时故障时已有容器仍可重启 |
| 时间 | 内部 NTP | **node1 作为集群内时间源**（`local stratum 10` + `allow 网段`，有内网 NTP 时作为上游），node2/3 `server node1 iburst` |
| Bootstrap | `--single-host-defaults` | **去掉**；node1 bootstrap 后手动加 node2/3 |
| MON/MGR | 1/1 | **3 MON**（三台）、**2 MGR**（active+standby） |
| MDS | 1 | **2**：1 active + 1 standby（`max_mds 1`） |
| OSD | 2 | **12**（每台 4 块），逐块按 `/dev/disk/by-id/` 添加，**严禁** `--all-available-devices` |
| Pool | size=1 | 默认 **size=3,min_size=2**（`cluster.conf` 可改为 2/1） |
| 容量 | — | 12 × 单盘容量 ÷ 3 ≈ 有效容量，再留 ~20–25% 余量 |

### 0.1 示例参数（全部写在 `offline/cluster.conf`）

| 配置 | 示例 |
|---|---|
| 主机名（= `hostname -s`） | `node1` `node2` `node3` |
| 存储 IP（bond0） | `10.250.0.11` `10.250.0.12` `10.250.0.13`，`PUBLIC_NETWORK=10.250.0.0/24` |
| Registry | `10.250.0.11:5000/ceph/ceph:v20.2.4` |
| OSD 盘 | 每台 4 条 `nodeX:/dev/disk/by-id/nvme-<型号>_<序列号>` |
| 副本 | `POOL_SIZE=3` `POOL_MIN_SIZE=2` |
| CephFS | `models`，pool `models_meta` / `models_data`，客户端 `client.modelreader`(r) / `client.modelwriter`(rw) |

### 0.2 结构

```text
              客户端 / K8s Worker（mount -t ceph, mon_addr=.11/.12/.13）
                               |
        ---------------- 存储网 10.250.0.0/24 (bond0) ----------------
        |                         |                          |
   node1 .11                  node2 .12                  node3 .13
   registry :5000 (HTTP)      chrony -> node1            chrony -> node1
   chrony server              MON, MGR(standby)          MON
   MON, MGR, MDS              MDS(standby/active)        OSD x4
   OSD x4                     OSD x4
   cephadm/admin keyring
```

### 0.3 步骤总览

| 阶段 | 地点 | 命令 | 完成条件 |
|---|---|---|---|
| ① 打包 | 联网机 | `build/build-bundle.sh` | bundle 目录 + `SHA256SUMS` + tar |
| ② 拷贝/解包 | 3 台 | `tar -xf ... -C /opt` → `/opt/ceph-offline` | `sha256sum -c` 通过 |
| ③ 配置 | 3 台同一份 | `offline/cluster.conf` | IP、主机名、by-id 核对 |
| ④ 安装 | **先 node1，再 node2/3** | `sudo ./install-node.sh` | 依赖装好，registry 可拉，`cephadm check-host` OK |
| ⑤ Bootstrap | node1 | `sudo ./bootstrap.sh` | 1 MON + 1 MGR，`ceph -s` 可用 |
| ⑥ 加主机 | node1（手工） | `./add-hosts.sh` 打印的命令 | 3 主机、3 MON quorum、2 MGR |
| ⑦ OSD | node1 | `./add-osds.sh` 预览 → `--yes-i-really-mean-it` | `12 osds: 12 up, 12 in` |
| ⑧ CephFS | node1 | `sudo ./setup-cephfs.sh` | MDS 1 active + 1 standby，PG `active+clean` |
| ⑨ 客户端 | 客户端 | 第 8 节 | 挂载、只读验证 |

---

## 1. 联网准备机：打包（`build/`）

要求：x86_64、能访问 quay.io / download.ceph.com / archive.ubuntu.com，装有 `podman`、`curl`、`python3`。**不要求**准备机本身是 Ubuntu：deb 是在**干净的 `ubuntu:24.04` 容器**里下载的，因此不会因准备机已安装某些包而漏下依赖（v1.0 1.4 节提到的问题）。

```bash
git clone <repo> Fast_deploy_ceph && cd Fast_deploy_ceph
cp offline/cluster.conf.example offline/cluster.conf   # 可在这里先填好，或到现场再填
OUT=$PWD/../Fast_deploy_ceph-bundle ./build/build-bundle.sh
```

脚本做了什么（等价于 v1.0 1.2–1.5）：

1. 下载 `https://download.ceph.com/rpm-20.2.4/el9/noarch/cephadm`（官方独立 cephadm，不是装 RPM），执行 `cephadm version` 确认 20.2.4。
2. `podman pull --arch amd64 quay.io/ceph/ceph:v20.2.4` 与 `docker.io/library/registry:2`，`podman save` 成 `images/*.tar`，记录架构与 digest 到 `images/ceph.inspect`。
3. `podman run --network host ubuntu:24.04 build/download-debs.sh`：对 `build/packages.list`（podman lvm2 chrony openssh-server python3 iproute2 netplan.io ethtool jq curl nvme-cli smartmontools ca-certificates ceph-common）做 `apt-rdepends` 全闭包下载 + 在干净底座上 `apt-get install --download-only` 补齐虚拟包 provider（如 t64 库），生成 `Packages(.gz)`；`unresolved-packages.txt` 中只应是虚拟包名。
4. 拷贝 `offline/`、`docs/` 进 bundle，生成 `SHA256SUMS`，打 `ceph-offline-20.2.4-bundle.tar` 并输出 tar 的 sha256。

> `ceph-common` 来自 Ubuntu 源（19.2.x），只用于节点/客户端上的 `mount.ceph` 与 `ceph` CLI 便利；集群守护进程全部来自 20.2.4 容器镜像。客户端离线挂载同样可用这个 deb 仓库。

搬运前后核对 tar 的 sha256。

---

## 2. 离线目标机：检查（3 台都做，不擦盘）

```bash
cat /etc/os-release; uname -m; hostname -s
ip -br address show bond0
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/ | grep -v -- -part
sudo wipefs -n /dev/disk/by-id/<每块数据盘>       # 只预览
ping -c2 10.250.0.11; ping -c2 10.250.0.12; ping -c2 10.250.0.13
```

- `hostname -s` 必须与 `NODE_NAMES` 一致；三台互相能用主机名解析（`/etc/hosts` 或 DNS），cephadm 会以主机名登记。
- 每台记录 4 块数据盘的 by-id（型号+序列号）、槽位，写入 `OSD_DEVICES`。系统盘绝不能出现在列表里。
- 网络/bond 按 v1.0 第 2 节，已配置好则只核对。

## 3. 解包与配置（3 台）

```bash
sudo tar -xf ceph-offline-20.2.4-bundle.tar -C /opt
sudo mv /opt/Fast_deploy_ceph-bundle /opt/ceph-offline
cd /opt/ceph-offline && sha256sum -c --quiet SHA256SUMS && echo OK
cd offline && sudo cp cluster.conf.example cluster.conf && sudo vi cluster.conf
```

三台用**同一份** `cluster.conf`（建议在 node1 改好后 scp 过去）。

## 4. 安装依赖 / 时间 / Registry：`install-node.sh`

**先 node1，再 node2、node3**（node2/3 会验证能从 node1 registry 拉镜像）：

```bash
cd /opt/ceph-offline/offline && sudo ./install-node.sh
```

脚本按角色执行（可重复运行）：

| 步骤 | 全部节点 | 仅 node1 |
|---|---|---|
| 校验 | `sha256sum -c SHA256SUMS`、OS/架构/IP 预检 | |
| APT | `deb [trusted=yes] file:///opt/ceph-offline/debs ./`，**只刷新离线源**，`apt-get install --no-download` | |
| SSH | `systemctl enable --now ssh` | |
| chrony | 注释掉默认 `pool`；写 `/etc/chrony/conf.d/ceph-offline.conf`：`server node1 iburst` | `local stratum 10`、`allow 10.250.0.0/24`（有内网 NTP 时加 `server <NTP> iburst`） |
| cephadm | 安装到 `/usr/local/sbin/cephadm` | |
| Registry 信任 | `/etc/containers/registries.conf.d/99-ceph-local.conf`：`location="10.250.0.11:5000"`, `insecure=true` | |
| 镜像 | `podman load` ceph 镜像并 tag 成 `10.250.0.11:5000/ceph/ceph:v20.2.4`（兜底） | load registry:2；systemd `ceph-local-registry.service`：`-p 10.250.0.11:5000:5000`；`podman push` |
| 检查 | `cephadm check-host` | `curl http://10.250.0.11:5000/v2/ceph/ceph/tags/list` 含 v20.2.4 |

手工等价命令（node1 registry 部分）：

```bash
sudo podman load -i /opt/ceph-offline/images/registry-2.tar
sudo podman load -i /opt/ceph-offline/images/ceph-v20.2.4.tar
# unit 中 ExecStart:
/usr/bin/podman run --rm --replace --name ceph-local-registry \
  -p 10.250.0.11:5000:5000 -v /var/lib/ceph-local-registry:/var/lib/registry docker.io/library/registry:2
sudo podman tag quay.io/ceph/ceph:v20.2.4 10.250.0.11:5000/ceph/ceph:v20.2.4
sudo podman push --tls-verify=false 10.250.0.11:5000/ceph/ceph:v20.2.4
```

**安全边界：** registry 只绑定存储网 IP，不监听 `0.0.0.0`；HTTP 无认证，存储网必须是受控内网。若有 UFW/ACL，只允许 node2/node3 访问 5000。

时间核对（三台）：`chronyc sources`（node2/3 应看到 `^* node1`）、`timedatectl`。Ceph MON 对时钟偏差敏感（默认 0.05 s 告警）。node1 若无上游 NTP，先在 node1 本地控制台把时间校准。

**registry 兜底说明：** cephadm 默认把 `container_image` 解析成 repo digest（`10.250.0.11:5000/ceph/ceph@sha256:...`），新部署守护进程时各节点会从 node1 拉取。node1 宕机期间已在运行的守护进程不受影响；因为每台都已 load 同一镜像（digest 相同），重启已有容器也不需要 registry。新增/重建守护进程需等 registry 恢复，或者临时 `podman load` 后执行。

## 5. Bootstrap（node1）：`bootstrap.sh`

```bash
cd /opt/ceph-offline/offline && sudo ./bootstrap.sh
```

等价手工命令：

```bash
sudo cephadm --image 10.250.0.11:5000/ceph/ceph:v20.2.4 inspect-image
sudo cephadm --image 10.250.0.11:5000/ceph/ceph:v20.2.4 bootstrap \
  --mon-ip 10.250.0.11 \
  --skip-monitoring-stack --skip-dashboard --skip-firewalld --allow-fqdn-hostname
#   [--cluster-network 10.251.0.0/24]   # 有独立复制网时
sudo cephadm shell -- ceph config set global public_network 10.250.0.0/24
sudo cephadm shell -- ceph config set global osd_pool_default_size 3
sudo cephadm shell -- ceph config set global osd_pool_default_min_size 2
sudo cephadm shell -- ceph config set mgr mgr/cephadm/use_repo_digest true
sudo cephadm shell -- ceph orch host label add node1 _admin
sudo cephadm shell -- ceph orch host label add node1 mon
sudo cephadm shell -- ceph orch host label add node1 mgr
sudo cephadm shell -- ceph -s
```

**不使用** `--single-host-defaults`：3 节点下 CRUSH 故障域保持默认 `host`，3 副本分布到 3 台主机。
期望：1 MON quorum、1 MGR active，`HEALTH_WARN`（无 OSD）属正常中间态。重复运行脚本会跳过已完成的 bootstrap，只重设参数。

## 6. 手工加主机（node1）

`./add-hosts.sh` **只打印**命令，按顺序人工执行（`--apply` 才自动执行）：

```bash
# 1) 分发 cephadm 公钥（任选其一）
ssh-copy-id -f -i /etc/ceph/ceph.pub root@10.250.0.12
ssh-copy-id -f -i /etc/ceph/ceph.pub root@10.250.0.13
#    无 root 密码登录时：把 /etc/ceph/ceph.pub 内容追加到 node2/3 的 /root/.ssh/authorized_keys
#    （Ubuntu 默认 PermitRootLogin prohibit-password，公钥登录可用）
# 2) 验证 cephadm 能连
sudo cephadm shell -- ceph cephadm check-host node2 10.250.0.12   # 可选
# 3) 加主机并打标签
sudo cephadm shell -- ceph orch host add node2 10.250.0.12 --labels mon,mgr
sudo cephadm shell -- ceph orch host add node3 10.250.0.13 --labels mon,mgr
# 4) 3 MON、2 MGR
sudo cephadm shell -- ceph orch apply mon --placement="3 label:mon"
sudo cephadm shell -- ceph orch apply mgr --placement="2 label:mgr"
# 5) 核对
sudo cephadm shell -- ceph orch host ls
sudo cephadm shell -- ceph orch ps --daemon-type mon
sudo cephadm shell -- ceph quorum_status -f json-pretty | grep -A4 quorum_names
```

可选：给 node2 加 `_admin` 标签（`ceph orch host label add node2 _admin`），cephadm 会同步 `/etc/ceph/ceph.conf` 与 admin keyring，作为第二个管理节点。

合格：3 台 `Status` 为空（非 Offline），`3 daemons, quorum node1,node2,node3`，`mgr: node1.xxx(active), standbys: node2.yyy`。

## 7. OSD：`add-osds.sh`（逐块 by-id，先预览）

```bash
sudo cephadm shell -- ceph orch device ls --wide --refresh   # 12 块都应 Available=Yes
sudo ./add-osds.sh                                # 只预览：主机/设备/将要执行的动作
sudo ./add-osds.sh --yes-i-really-mean-it         # 真正创建（会擦除这些盘）
sudo ./add-osds.sh --host node2 --yes-i-really-mean-it   # 也可按主机分批
```

等价手工命令（每块一条）：

```bash
sudo cephadm shell -- ceph orch daemon add osd node1:/dev/disk/by-id/nvme-<MODEL>_<SERIAL>
...（共 12 条）
```

- **严禁** `ceph orch apply osd --all-available-devices`。
- 脚本对已是 OSD 的盘自动跳过（按 `ceph osd metadata` 中的设备名比对），重复运行安全；ceph-volume 也会拒绝有分区/LVM/签名的盘。
- 如盘上有旧签名，人工确认后才 `ceph orch device zap <host> <path> --force`。

验收：`ceph osd tree` 每个 host 下 4 个 OSD；`ceph osd stat` → `12 osds: 12 up, 12 in`。

## 8. CephFS + 客户端：`setup-cephfs.sh`

```bash
sudo ./setup-cephfs.sh
```

等价：

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

（以上 `ceph ...` 均用 `sudo cephadm shell -- ceph ...` 执行。）

- PG 数为 12 OSD 下的起点值，默认开启的 pg_autoscaler 会调整。
- `POOL_SIZE=2,POOL_MIN_SIZE=1` 时：坏一台仍可读写，但此时只剩 1 份数据，期间再坏一块盘即丢数据。**不推荐 min_size=1**。
- 验收：`ceph fs status models` 显示 1 个 `active` + 1 个 `standby`；`ceph osd pool ls detail` 两个 pool `size 3 min_size 2`；`ceph -s` `HEALTH_OK`、PG 全部 `active+clean`。

客户端挂载（三个 MON 都写上，任何一台宕机仍可挂载）：

```bash
sudo mkdir -p /etc/ceph /mnt/models
sudo install -m 600 modelreader.secret /etc/ceph/modelreader.secret
sudo mount -t ceph modelreader@.models=/ /mnt/models \
  -o mon_addr=10.250.0.11:3300/10.250.0.12:3300/10.250.0.13:3300,secretfile=/etc/ceph/modelreader.secret,_netdev
```

fstab：

```fstab
modelreader@.models=/  /mnt/models  ceph  mon_addr=10.250.0.11:3300/10.250.0.12:3300/10.250.0.13:3300,secretfile=/etc/ceph/modelreader.secret,_netdev,nofail,x-systemd.automount  0  0
```

离线客户端如需 `mount.ceph`：把 bundle 的 `debs/` 作为本地源，`apt-get install --no-download ceph-common`。只读账号写文件应被拒绝；不要把 admin keyring 发给客户端。K8s 接入、防火墙端口表见 v1.0 第 8 节（端口：3300/6789 MON，6800–7568 OSD/MDS，22 SSH，5000 仅 node1↔node2/3）。

## 9. 3 节点验收清单（在 v1.0 第 9 节基础上增加）

| 测试 | 操作 | 合格 |
|---|---|---|
| 时间 | `chronyc sources` 三台；`ceph health detail` | 无 `MON_CLOCK_SKEW` |
| Registry | node2/3：`podman pull --tls-verify=false 10.250.0.11:5000/ceph/ceph:v20.2.4` | 成功 |
| MON | `ceph quorum_status` | 3 个在 quorum |
| MGR | `ceph mgr stat` / `ceph -s` | 1 active + 1 standby |
| OSD | `ceph osd tree` | 3 host × 4 OSD，全部 up/in |
| 副本 | `ceph osd pool ls detail` | size 3 / min_size 2（或按配置） |
| MDS | `ceph fs status` | 1 active + 1 standby |
| 主机故障 | 维护窗口内关 node3（或 node2） | 客户端仍可读写，`HEALTH_WARN`（degraded），恢复后回到 `active+clean` |
| MGR/MDS 切换 | `ceph mgr fail` / `ceph mds fail models:0` | standby 接管 |
| node1 重启 | 重启 node1 | registry 自启，MON 回到 quorum |

## 10. 上线前确认

- [ ] 三台 `hostname -s`、IP、互相解析、时间同步正确
- [ ] 12 块数据盘 by-id 与槽位对应表已记录；系统盘不在列表
- [ ] `install-node.sh` 三台成功，`cephadm check-host` OK
- [ ] node1 registry 开机自启，node2/3 能拉取
- [ ] 3 MON / 2 MGR / 2 MDS / 12 OSD 全部正常
- [ ] pool size/min_size 符合决策（默认 3/2）
- [ ] 客户端挂载、只读校验、单台主机故障演练通过
- [ ] 备份：`/etc/ceph/*`（admin keyring 敏感）、`cluster.conf`、`/var/lib/ceph-local-registry`、bundle

