# S3 VIP + BGP：依赖与一键部署脚本接入信息

适用本次已验证环境：Ubuntu24.04 amd64虚拟机，Ceph20.2.4 Tentacle，FRR8.4.4，H3C S6850 Comware R6715。当前稳定态分流已验证64/64成功，VM41/42分别27/37个连接。

## 1. 当前环境实际新增的3个包

| 包 | 固定验证版本 | 用途 |
| --- | --- | --- |
| frr | 8.4.4-1.1ubuntu6.7 | bgpd、zebra、vtysh、FRR服务 |
| libcares2 | 1.27.0-1.0ubuntu1 | FRR直接依赖库 |
| libyang2t64 | 2.1.30-2.1ubuntu0.1 | FRR直接依赖库 |

本次3个deb未提交git；文件名、来源仓库路径与SHA256位于[package-manifest.json](reference/package-manifest.json)。这些是相对当前Ubuntu云镜像的增量，不是任意空系统上的完整依赖闭包。不要把Ubuntu的t64包直接用于其他发行版/版本/架构。

## 2. FRR包本身的依赖

以下直接从本目录实际使用的 `frr_8.4.4-1.1ubuntu6.7_amd64.deb` 的control元数据读取：

```text
Pre-Depends: adduser
Depends:
  iproute2
  logrotate (>= 3.2-11)
  lsof
  libc6 (>= 2.38)
  libcap2 (>= 1:2.10)
  libcares2 (>= 1.7.0)
  libcrypt1 (>= 1:4.1.0)
  libjson-c5 (>= 0.15)
  libpam0g (>= 0.99.7.1)
  libreadline8t64 (>= 7.0~rc1)
  libyang2t64 (>= 2.0.0~)
Recommends: frr-pythontools
Suggests: frr-doc
```

当前实现不调用frr-pythontools，也不需要frr-doc；是否自动安装推荐包由打包策略决定。其余基础依赖在本次云镜像中已有。离线一键包应基于目标发行版、版本、架构和最小基础镜像，用APT解析并收齐传递依赖，不能仅假设上述3个增量包在所有目标环境都足够。

## 3. 配置和健康控制所需的基础组件

| 位置 | 依赖 | 用途 |
| --- | --- | --- |
| RGW VM | python3 | network.py、health.py；只用标准库，无pip依赖 |
| RGW VM | iproute2 | ip link/address/route，dummy接口 |
| RGW VM | procps | sysctl，VM接口ARP控制 |
| RGW VM | systemd | 服务顺序、notify、watchdog、启动/停止管理 |
| RGW VM | openssh-server、sudo | 当前远程部署入口和sudo -n；不是BGP协议依赖 |
| 现有Ceph | cephadm及当前容器引擎 | 复用已有Ceph/RGW/ingress部署能力 |
| 现有Ceph ingress | HAProxy2.3、Keepalived2.2.4容器 | 复用已有镜像，不另装宿主机haproxy/keepalived包 |
| 工作站 | Python + Paramiko | 当前vm_runner与同步测试控制器；无需装到RGW VM |
| 跳板.22 | openssh-client及既有密钥/known_hosts | 当前实验室访问路线；独立部署工具可使用自己的已有SSH方式 |

分流抓取与HTTP探测只用Linux/Python标准库，不依赖tcpdump、boto3或curl。BGP服务本身不依赖工作站或跳板常驻。

## 4. 接入一键部署脚本时需要参数化

本目录脚本是带环境保护的实验实现，不能不改参数就套到其他集群。至少抽出：

```text
ENABLE_S3_BGP
RGW/ingress节点清单与各自本机IP
VIP与前缀长度：本例10.11.4.50/32
现有VRRP VIP：本例10.11.4.50/24
前端/统计/RGW端口：80 / 1968 / 8080
VM业务接口：本例enp1s0
dummy名称：本例s3vip50
本地ASN / peer ASN / peer IP：65050 / 65000 / 10.11.4.1
每节点router-id：本机IP
keepalive / hold：3 / 9
Ceph fsid、RGW和ingress service名称
HAProxy统计配置路径与frontend/backend名称
健康检测方式、成功/失败阈值及轮询间隔
是否保留VRRP同网段L2兼容路径
```

`health.py`和`network.py`内的hostname/VIP/ASN当前是本实验的固定保护条件；通用实现应从校验过的配置读取。HAProxy路径里的daemon随机后缀不能固化到通用部署脚本，应在ingress就绪后发现路径，并考虑cephadm重新部署后的路径更新。

推荐接入顺序：原Ceph/RGW/ingress正常→检查现有FRR和IP冲突→安装依赖并先禁止FRR自动启动→保存原配置与ARP值→生成dummy/FRR/健康服务→原生语法检查→启动dummy→FRR→健康控制→确认只发布一个/32→用户执行独立交换机命令→验收并记录结果。已有集群不可因此重新清盘或重建Ceph。

当前设计的几个必要约束：

- 保留VRRP时，仅VM业务接口设置arp_ignore=1、arp_announce=2，避免仅dummy持有VIP的备节点参与ARP应答。
- FRR磁盘配置不固化network VIP；健康服务运行时增删前缀，停止/失败时撤销。
- Ubuntu的zebra/staticd默认启动，仅启用bgpd=yes，bfdd=no；不添加不存在的zebra=yes配置项。
- H3C需先在AF enable peer再配置其过滤；使用实例级ignore暂缓建邻，过滤和route-limit完成后再undo ignore。
- 当前健康检测依赖匿名GET返回S3 XML；通用脚本应将健康检查方式参数化，不能假设所有S3安全策略都允许匿名根目录GET。
- 同网段客户端直接ARP时走VRRP单入口；验证ECMP需要让测试源经Leaf路由，不能把后端RGW的轮询当作入口ECMP证据。

主入口：[CONFIGURATION.md](CONFIGURATION.md)、[configure_vms.py](reference/configure_vms.py)、[switch/apply.txt](switch/apply.txt)、[TESTING.md](TESTING.md)。
