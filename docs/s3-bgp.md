# S3 入口：VIP（默认）与 BGP/ECMP（可选）

本工具包的 S3 入口有两种形态。**默认只有 VIP**；BGP 是独立、默认关闭、需单独触发的附加功能，
它**不替换**也**不修改** VIP 路径。

| | VIP（默认，`RGW_INGRESS=1`） | BGP/ECMP（可选，`ENABLE_S3_BGP=1`） |
|---|---|---|
| 由谁部署 | `deploy.sh` 默认 `rgw` 阶段 → `setup-rgw.sh`（cephadm `ingress.rgw.<id>`：haproxy + keepalived） | 只由 `./deploy.sh --only s3-bgp` 或 `./setup-s3-bgp.sh` |
| 入口地址 | `RGW_VIP`（VRRP，`RGW_VRRP_ROUTER_ID`，默认 60） | 同一个 VIP，各 RGW 节点再以 `/32` 经 BGP 发布给 Leaf |
| 转发 | 同 VLAN ARP 到 VRRP 主，单活 | 经 Leaf 路由查找的流量按流哈希 ECMP 到多个 HAProxy；同 VLAN 直连客户端仍走 VRRP 主 |
| 节点改动 | 仅 cephadm 容器 | FRR（只装在 `S3_BGP_HOSTS`）+ 自有 dummy `S3_BGP_DUMMY` 持有 VIP/32 + 业务网卡 `arp_ignore=1/arp_announce=2` + 两个 systemd 服务 |
| 交换机 | 无 | **人工**配置 BGP peer（[s3-bgp-switch-h3c.md](s3-bgp-switch-h3c.md)），脚本从不登录交换机 |
| 健康 | haproxy 后端检查 + keepalived | `s3-bgp-health`：本机 HAProxy 统计 + 本机 RGW 探测，健康才发布 `/32`，失败/停止即撤销 |

两条 BGP 路由都撤销时，Leaf 回落到 `/24` 直连 + VRRP，VIP 仍可能可达——**不能用“VIP 不通”判断撤路是否生效**，要看 Leaf 路由表。

## 边界（脚本保证）
- 只改：业务网卡（`S3_BGP_IFACE`，空 = 持有节点 IP 的网卡）的 `arp_ignore/arp_announce`（原值备份在 `/var/lib/fast-deploy-s3-bgp/arp-before.conf`，teardown 恢复）；自建 dummy（`alias fast-deploy-s3-bgp`，已存在且非本工具创建 → 拒绝）。
- 不碰：管理 IP、默认路由、MTU、物理/网桥/VLAN 配置、keepalived/HAProxy、`setup-rgw.sh`/`setup-ingress-vip.sh`。
- `/etc/frr/frr.conf`：只有在“不存在 / 与 frr 包默认文件一致（dpkg conffile md5）/ 本工具生成（首行 `! managed-by: fast-deploy-s3-bgp`）”时才写；否则**拒绝并且不做任何改动**。首次运行时把原 `frr.conf`、`daemons` 备份到 `/var/lib/fast-deploy-s3-bgp/backup/`。
- `frr.conf` 不含 `network` 语句；VIP/32 只在健康时由 `s3-bgp-health` 通过 `vtysh` 运行时加入/删除（不 `write`）。出向 prefix-list 只允许 VIP/32，入向全拒绝；`bgp ebgp-requires-policy`、`bgp network import-check`、`no bgp default ipv4-unicast`。
- `/etc/frr/daemons`：只改 `bgpd=yes`、`bfdd=no` 两行（zebra/staticd 由 Ubuntu FRR 隐式启动）。
- FRR 从离线包本地仓库安装，仅在 `S3_BGP_HOSTS`；安装期间用临时 `policy-rc.d` 阻止未配置的 frr 自启（若已存在他人的 `policy-rc.d` 则拒绝）。`install-node.sh` 不安装 FRR。
- 安装前做原生检查：`/usr/lib/frr/bgpd -C -f <渲染的 frr.conf>`、`systemd-analyze verify <units>`；装好后检查启动事务（`systemd-analyze verify default.target`）中没有涉及 frr/s3-bgp 的顺序环。首次 setup 失败自动 teardown 回退；已有 setup 上重跑失败则不回退、报错。
- 幂等：只写有变化的文件；无变化不重启服务。
- HAProxy 配置路径运行时发现：`S3_BGP_HAPROXY_CFG` 或 `S3_BGP_HAPROXY_GLOB`（默认 `/var/lib/ceph/*/haproxy.rgw.<RGW_SERVICE_ID>.*/haproxy/haproxy.cfg`，取最新）。`stats auth` 只在运行时从该文件读取，经 stdin（`curl -K -`）传给 curl，不进 argv、日志、git。

## 健康判定（`/usr/local/lib/fast-deploy-s3-bgp/health.sh`）
健康 = HAProxy 统计 CSV（`S3_BGP_STATS_URL`，默认 `http://<节点IP>:RGW_MONITOR_PORT/stats;csv`）中
`S3_BGP_FRONTEND_NAME/FRONTEND` 为 `OPEN` **且** `S3_BGP_BACKEND_NAME` 下至少一个以 `S3_BGP_BACKEND_SERVER_PREFIX` 开头的 server 为 `UP*`
**且** 本机探测通过：

| `S3_BGP_PROBE_MODE` | 判定 |
|---|---|
| `anon-xml`（默认） | `GET S3_BGP_PROBE_URL` → 200 且含 `S3_BGP_PROBE_EXPECT`（默认 `ListAllMyBucketsResult`） |
| `http-status` | HTTP 码在 `S3_BGP_PROBE_CODES`（默认 `200 403`；匿名被拒的严格 S3 策略用它） |
| `tcp` | 能连上 `S3_BGP_PROBE_URL` 的 host:port |
| `none` | 只看 HAProxy |

连续 `S3_BGP_RISE`（3）次好 → 发布；连续 `S3_BGP_FALL`（2）次坏 → 撤销；每 `S3_BGP_INTERVAL`（2）秒。服务 `Type=notify`、`WatchdogSec=S3_BGP_WATCHDOG_SEC`（15），`ExecStartPre`/`ExecStopPost` 都撤销；FRR 重启后下一轮自动补发。
维护：`touch /run/fast-deploy-s3-bgp.disabled` → 2 个周期内撤路；`rm` 后 3 个周期恢复。状态：`cat /run/fast-deploy-s3-bgp-health.state`；日志：`journalctl -u s3-bgp-health`。

## 使用顺序
1. 默认一键部署完成，`RGW_INGRESS=1` 的 VIP 已可用（`verify.sh` 通过）。
2. `cluster.conf` 设置 `ENABLE_S3_BGP=1`、`S3_BGP_PEER_IP`（Leaf 业务网关）、`S3_BGP_PEER_ASN`，按需 `S3_BGP_LOCAL_ASN`/`S3_BGP_ROUTER_IDS`/`S3_BGP_IFACE`/`S3_BGP_DUMMY`/探测参数（见 `cluster.conf.example` 末尾）。
3. `sudo ./validate.sh`：配置校验 + 每台 BGP 主机：离线包有 frr deb、已有 frr.conf 归属、dummy 名冲突、TCP 179（未配交换机时仅告警）。
4. `sudo ./setup-s3-bgp.sh --dry-run`（或 `./deploy.sh --dry-run --only s3-bgp`）：打印每台的 frr.conf/sysctl/动作，不改任何东西、不 ssh。
5. `sudo ./deploy.sh --only s3-bgp`（= `./setup-s3-bgp.sh`；`--host node2` 只做一台）。逐台：推送脚本 → 预检 → 装 FRR → 渲染+原生检查 → 安装 → 启动 `s3-bgp-network`、`frr`、`s3-bgp-health`。
6. 交换机侧人工执行：[s3-bgp-switch-h3c.md](s3-bgp-switch-h3c.md)。
7. `sudo ./verify.sh`：每台报告 `LOCAL-OK`（健康服务运行、peer Established、只发布 VIP/32、收到 0 条）/ `PENDING-SWITCH`（本机就绪、peer 未建立）/ `WITHDRAWN-UNHEALTHY` / `FAIL`。这只是**节点侧**结论；端到端 ECMP 必须从经 Leaf 路由的客户端测（多次独立 TCP 连接，按源端口哈希，不要求 50/50；参见 `doc/s3-vip-bgp-20261027/TESTING.md`）。

`s3-bgp` 不在默认阶段列表，`--from` 不会跑到它；`ENABLE_S3_BGP=0` 时 `deploy.sh` 的默认行为与 oneclick.1 完全一致（干跑输出逐行比对，见 release notes）。

## 回退
1. 先交换机：[s3-bgp-switch-h3c.md#回退](s3-bgp-switch-h3c.md#回退)。
2. `sudo ./teardown-s3-bgp.sh --dry-run`，然后 `sudo ./teardown-s3-bgp.sh [--host nodeX]`：撤 /32 → 停用健康/网络服务 → 删除自有 dummy → 恢复 ARP 原值 → `frr.conf`/`daemons` 从备份恢复（frr.conf 仅当仍是本工具生成）→ 删除单元/drop-in/sysctl 文件 → frr.service 恢复到 setup 前的 enabled/active 状态。frr 包保留。VIP（keepalived）不受影响。

## 文件
| 节点路径 | 来源 |
|---|---|
| `/usr/local/lib/fast-deploy-s3-bgp/{network.sh,health.sh}` | `offline/s3-bgp/` |
| `/etc/fast-deploy-s3-bgp/s3-bgp.conf` | 由 cluster.conf 渲染的单节点参数（0600） |
| `/etc/frr/frr.conf`、`/etc/frr/daemons` | `templates/frr.conf.in`；daemons 两行 |
| `/etc/systemd/system/s3-bgp-network.service`、`s3-bgp-health.service`、`frr.service.d/fast-deploy-s3-bgp.conf` | `templates/*.in` |
| `/etc/sysctl.d/90-fast-deploy-s3-bgp.conf` | `templates/sysctl-s3-bgp.conf.in` |
| `/var/lib/fast-deploy-s3-bgp/` | 备份、ARP 原值、frr 原状态、`managed-files.sha256` |

单测：`offline/tests/test-s3-bgp.sh`（HAProxy CSV 解析、rise/fall、stats 认证不进 argv、探测模式、维护开关、vtysh 撤销容错、frr.conf/dummy 拒绝覆盖、配置校验、setup/teardown/deploy 干跑）。

## 容器集成测试（systemd + 真 FRR，2026-10-27）
在一台 Ubuntu 24.04 主机上用 3 个 systemd 容器（node1、node2 跑本工具；sw 用同一离线包的 FRR 模拟 Leaf，AS65000）+ 假 HAProxy stats/RGW（Python 测试桩，仅测试用），已验证：
- FRR 从离线包 `--no-download` 安装（无网络源），`policy-rc.d` 阻止自启；宿主已有 `policy-rc.d` 时在只读预检阶段拒绝、不做任何改动。
- `bgpd -C`、`systemd-analyze verify` 通过；`Type=notify`/`WatchdogSec` 生效（SIGSTOP 后 15 s 看门狗重启；SIGKILL 后 `ExecStopPost` 立即撤路）。
- eBGP 建链（timers 3/9），只发 VIP/32，入向全拒绝（对端发 3 条，本端 pfxRcd=0）；sw 上形成 2 路 ECMP。
- 后端全 DOWN 4 s 撤路（fall 2×2 s），恢复后 7 s 重新发布（rise 3×2 s）；维护开关撤路；`systemctl restart frr` 后由健康服务重新加入。
- 重跑幂等（0 文件变化、BGP 会话不重置）；升级只改变的文件。
- 重启容器（模拟重启）后 dummy、ARP、frr、健康服务自动恢复并重新发布。**此测试发现并修复了一个启动顺序环**（frr drop-in 曾 `After=s3-bgp-network`，而 frr 是 `Before=network.target`），setup 现在会用 `systemd-analyze verify default.target` 检查涉及 frr/s3-bgp 的顺序环并拒绝。
- teardown：撤路、删 dummy、ARP 恢复为 0/0、frr.conf 恢复为包默认（md5 一致）、frr 恢复为 setup 前 disabled/inactive、所有自有文件删除；默认路由不变；二次 teardown 无害。
- 他人的 frr.conf / 同名非自有接口：拒绝且不改动。
- `verify.sh` 的 BGP 段：LOCAL-OK / WITHDRAWN-UNHEALTHY / PENDING-SWITCH 三种状态（**此测试发现并修复了 JSON 字段**：`show bgp ipv4 unicast summary json` 的 `.peers` 在顶层）。

测试环境限制：该主机内核没有 `dummy` 模块，容器内用测试专用的 `ip` 包装把 dummy 换成 bridge 设备；交换机是 FRR 而非 H3C。

## 未在真机验证（需授权实验节点）
真 dummy 接口（内核 `dummy` 模块）、真实 cephadm HAProxy stats/RGW、H3C Leaf（`docs/s3-bgp-switch-h3c.md` 的命令）、业务网卡为 bond/VLAN 时的 ARP 键名与 udev 下的 sysctl 持久化、物理机重启、双入口真实流量分流与故障切换时延、与 keepalived VIP 同网段共存的 ARP 行为。
