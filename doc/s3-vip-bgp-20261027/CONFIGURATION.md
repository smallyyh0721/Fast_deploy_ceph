# 已验证配置和实施过程

此文档说明2026-10-27实验配置及其来源。配套生产脚本尚未改造，原始实验代码仅作为后续实现参考。

## 1. 现有Ceph与新增BGP的边界

| 项目 | 实验值 |
| --- | --- |
| Ceph | 20.2.4 Tentacle，fsid `16c96e91-d119-11f1-9c37-021104000028` |
| 三台VM | nettest-40/41/42，10.11.4.40/41/42；每台4个OSD |
| RGW | `rgw.main`，入口节点VM41/42，各监听8080 |
| 现有ingress | `ingress.rgw.main`，HAProxy2.3 + Keepalived2.2.4，VIP `.50/24`，前端80、统计1968 |
| VM新增地址 | 每台入口的dummy `s3vip50`，`.50/32` |
| VM FRR | 本地AS65050，router-id为本机IP，对等体`.1` AS65000，timers3/9 |
| Leaf | H3C S6850-56HF，Comware R6715 / R6715HS02；管理`10.11.8.51`，SVI`10.11.4.1`；AS65000，IPv4 AF `balance ebgp 2` |
| 过滤 | VM出向只允许`.50/32`，入向全拒绝；Leaf每邻居入向只允许`.50/32`，出向全拒绝，route-limit1 |

最近健康记录为12OSD up/in、321PG active+clean，已有MON_CLOCK_SKEW告警。BGP改造未校时、改池、处理OSD、重新部署Ceph或重启现有RGW/HAProxy/Keepalived。

原Ceph一键部署及cluster.conf参数见[历史部署记录](historical-ceph-deployment.md)。那是已经完成的部署，不是要求后续agent对当前运行集群重新执行deploy/清盘。

## 2. VM端配置

所有VM端快照在[reference/configs](reference/configs/README.md)，分别以`vm-10.11.4.41`、`vm-10.11.4.42`为目录。结构映射实际安装路径：

```text
etc/frr/frr.conf
etc/frr/daemons.required-flags.txt
etc/s3-bgp-vip50/settings.json
etc/sysctl.d/90-s3-bgp-vip50.conf
etc/systemd/system/s3-vip50-network.service
etc/systemd/system/s3-vip50-health.service
etc/systemd/system/frr.service.d/s3-vip50.conf
opt/s3-bgp-vip50/network.py
opt/s3-bgp-vip50/health.py
```

`daemons.required-flags.txt`仅为bgpd=yes、bfdd=no的修改项，不能当整个daemons文件覆盖；Ubuntu自动启动zebra/staticd。`haproxy-public-excerpt.txt`只是原入口公开字段摘录，不是完整可部署配置。Ceph服务的公开字段快照见[ceph-services-selected-fields.json](reference/configs/ceph-services-selected-fields.json)。

### 地址和ARP

本例的等效操作如下，由网络unit拥有并执行，不应在已有节点盲目重放：

```bash
sudo -n sysctl -w net.ipv4.conf.enp1s0.arp_ignore=1 net.ipv4.conf.enp1s0.arp_announce=2
sudo -n ip link add s3vip50 type dummy
sudo -n ip link set s3vip50 up
sudo -n ip address replace 10.11.4.50/32 dev s3vip50
```

Keepalived仍只在主VM业务接口上持有`.50/24`，两个dummy均持有`.50/32`。arp_ignore=1避免仅在dummy持有VIP的备节点对业务接口ARP应答。脚本记录原ARP参数，停止时仅删除自己拥有的dummy并恢复参数；不删除Keepalived持有的地址，不改物理宿主机接口。

### 健康控制

[health.py](reference/health.py)读取现有HAProxy本机统计入口，统计认证只在VM内存中使用。要求数据frontend OPEN、至少一个RGW backend UP、本机RGW根目录GET返回S3 XML；连续3次成功发布、2次失败撤销，轮询间隔2秒。systemd watchdog15秒，停止服务额外撤销。

运行时通过vtysh增删`network 10.11.4.50/32`，磁盘frr.conf不固化该语句。维护标记是`/run/s3-vip50-bgp.disabled`。当前实验的匿名GET、stats路径、frontend/backend名均需在通用实现中参数化；不要导出认证值或Ceph keyring。

### 安装顺序

1. 读取已有Ceph、网络和FRR配置，确认入口服务已运行；保留配置/服务/ARP基线。
2. 安装FRR依赖但先阻止未配置的FRR自动启动。实验VM DNS失败时使用已核对SHA256的离线deb，没有改DNS。
3. 写入配置、网络脚本、健康脚本、unit和sysctl文件；已有不同FRR配置拒绝直接覆盖。
4. 执行native与unit检查：

```bash
sudo -n /usr/lib/frr/bgpd -C -f /etc/frr/frr.conf
sudo -n systemd-analyze verify /etc/systemd/system/s3-vip50-network.service /etc/systemd/system/s3-vip50-health.service
```

5. daemon-reload→启动dummy服务→FRR→本机健康检查→健康服务；检查精确连接/32及本地发布，再enable相关服务。
6. 维护标记和停止健康服务的撤销/恢复均通过VM本地测试。记录文件清单与SHA256用于回退。
7. 用户配置交换机后，复查两端Established、发布1条/接收0条，再执行真实路由分流测试。

## 3. 交换机端

完整命令：[apply.txt](switch/apply.txt)。实际运行配置：[running-bgp.txt](switch/running-bgp.txt)及[prefix-lists.txt](switch/prefix-lists.txt)。验收命令：[check.txt](switch/check.txt)。回退：[rollback.txt](switch/rollback.txt)。

AF级过滤要在AF peer enable之后配置。原实验先过滤后enable时报`The specified peers don't exist`。修正后在BGP实例级ignore暂时阻止会话，AF enable后完成过滤和route-limit，再回实例undo ignore。当前运行配置无残留ignore。

只创建本方案BGP邻居和精确策略；无重分发、默认路由发布、静态VIP路由、VLAN/SVI/物理口/哈希变化。交换机命令由用户执行，助手只读复查，未自动save。

已观测：两个Established，各接收1条；BGP表2 available/2 best；RIB和FIB有`.41/.42`两个可用下一跳。FIB额外的`.50→.50`仅H、无U，和原ARP主机邻接一致，不是第三条可用ECMP路径。

## 4. 数据流与回退

普通同VLAN访问直接ARP，保留VRRP单主。经Leaf路由查找的`.50/32`才走ECMP。后端两个RGW收到请求不等于入口分流；已用真实源端口及网关源MAC关联入口证据，见[测试说明](TESTING.md)。

两条BGP都撤回时，可能回落到/24直连+VRRP，不保证VIP不可达。单入口撤路后的Leaf收敛仍待单独验证。

回退时先撤销健康发布，再停FRR和本方案网络服务、恢复原ARP与配置；保留原RGW/ingress。交换机优先仅删除本次peer和策略，不误删其他后续BGP使用者。通用一键脚本仍需实现并测试这些回退路径。

参考：[Ceph Tentacle RGW服务](https://docs.ceph.com/en/tentacle/cephadm/services/rgw/)、[FRR8.4 BGP](https://docs.frrouting.org/en/stable-8.4/bgp.html)、[H3C Release6715 BGP](https://www.h3c.com/en/d_202501/2346092_294551_0.htm)。
