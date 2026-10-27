# S3 VIP + BGP/ECMP：后续 agent 接入一键离线包的交接

日期：2026-10-27。代码接入点依据本仓库 `578b1e19486a579710634f9072f3f582bd83a188` 检查。此提交上传文档、实验参考实现和证据，**没有给现有deploy.sh添加BGP能力，也没有构建或发布新的离线包**。

## 已验证的方案

Ceph20.2.4实验fsid `16c96e91-d119-11f1-9c37-021104000028`，VM `.40/.41/.42`。复用现有cephadm `ingress.rgw.main`：VIP `10.11.4.50:80`，HAProxy2.3 + Keepalived2.2.4，RGW后端 `.41/.42:8080`。两台入口VM新增dummy `.50/32`、FRR AS65050，向H3C Leaf `.1` AS65000发布精确/32，Leaf执行两下一跳ECMP。

保留原VRRP同网段ARP兼容入口。普通同VLAN客户端直接ARP仍走单主；经Leaf路由查找的流量才能验证入口ECMP。保留VRRP时，仅dummy持有VIP的备节点通过VM业务接口ARP参数避免抢答。

现场稳定态分流验证通过：64次独立TCP GET均返回HTTP200与S3 XML，VM41/42分别命中27/37个真实客户端源端口，无缺失、无重复，报文以太网源MAC为Leaf网关MAC。探测后VM40临时路由和accept_redirects恢复，两端BGP与入口健康复查正常。见 [结果](evidence/split-result.json)。**单入口撤路后的Leaf收敛、VM重启持久化、性能和签名对象读写不在此PASS范围内。**

## 关键文件指引

| 先看什么 | 文件 | 后续用途 |
| --- | --- | --- |
| 配置、命令与过程 | [CONFIGURATION.md](CONFIGURATION.md) | 复现设计及明确原Ceph与新增BGP的边界 |
| 完整依赖与参数化要求 | [DEPENDENCIES.md](DEPENDENCIES.md) | Ubuntu离线依赖闭包、参数模型、部署顺序 |
| 交换机命令 | [switch/apply.txt](switch/apply.txt) / [check.txt](switch/check.txt) / [rollback.txt](switch/rollback.txt) | 按H3C R6715生成供用户执行的命令；不在部署中自动登录交换机 |
| 实际交换机配置快照 | [switch/running-bgp.txt](switch/running-bgp.txt) / [prefix-lists.txt](switch/prefix-lists.txt) | 对照已成功配置，AF enable须先于过滤 |
| dummy与ARP控制 | [reference/network.py](reference/network.py) | VM接口限定、回退原ARP值、VIP接口管理 |
| 健康控制BGP发布 | [reference/health.py](reference/health.py) | HAProxy/RGW健康、动态/32、systemd notify/watchdog、停止撤路 |
| 文件生成/安装顺序 | [reference/configure_vms.py](reference/configure_vms.py) | FRR、systemd、sysctl与备份管理参考；实验脚本需重构后才能通用 |
| VM配置快照 | [VM41 FRR](reference/configs/vm-10.11.4.41/etc/frr/frr.conf) / [VM42 FRR](reference/configs/vm-10.11.4.42/etc/frr/frr.conf) | 同目录包括systemd、settings、sysctl及公开HAProxy摘录 |
| 已验证包版本/哈希 | [reference/package-manifest.json](reference/package-manifest.json) | 3个增量包的版本、仓库路径、SHA256；deb未提交git |
| 测试方法及脚本 | [TESTING.md](TESTING.md) | 避免将后端RGW轮询误判为入口ECMP |
| 原Ceph部署历史 | [historical-ceph-deployment.md](historical-ceph-deployment.md) | 已运行集群的参数及原始离线包来源；禁止按历史记录重新清盘 |

`reference/`是实验参考快照，**不是offline/的生产入口**。尤其`configure_vms.py`仍引用原工作区的vm_runner/baseline，不能从本仓库直接运行；节点名、地址、VIP、ASN、网卡、fsid、HAProxy路径含实验值，必须先参数化。目标节点健康/网络脚本使用Python标准库；当前工作站测试控制器使用Paramiko，这不是目标VM运行依赖。

原工作区材料目录为 `D:\dev\tokenfactory\Test_ceph\s3-bgp-vip50-20261027\`。本次交接已将实现所需的代码、配置和摘要证据复制进仓库，不应依赖其他agent恰好拥有该本机路径或口令。

## 当前仓库的具体改造点

| 仓库文件 | 后续需要处理的内容 |
| --- | --- |
| [offline/cluster.conf.example](../../offline/cluster.conf.example) | 增加默认关闭的S3_BGP开关及peer/ASN/router-id/接口/dummy/健康检测参数，复用现有RGW_*字段；不复用MON VIP作为S3 VIP |
| [offline/lib.sh](../../offline/lib.sh) | 新字段默认值、类型/范围校验和模板变量；保留现有非BGP行为 |
| [build/packages.list](../../build/packages.list) | 加入FRR及缺失基础工具；或分离可选FRR列表，由构建和节点安装共同消费 |
| [build/download-debs.sh](../../build/download-debs.sh) | 复用干净ubuntu:24.04中的递归依赖解析、虚拟依赖提供者和APT下载校验；不仅复制实验3个增量deb |
| [offline/install-node.sh](../../offline/install-node.sh) | 本地APT离线安装FRR依赖；处理已有FRR/服务自动启动与保护；明确安装哪些节点，不能将全部节点都设成BGP入口 |
| [offline/setup-rgw.sh](../../offline/setup-rgw.sh) | 等RGW及ingress真实就绪再发现HAProxy配置/统计入口；复用已有HAProxy和Keepalived，不重复部署第二套入口 |
| 拟新增 `offline/setup-s3-bgp.sh` 及支持文件 | 参数化模板、所有权/幂等/备份/回退、native检查；只改目标VM接口和自己创建的dummy；开关关闭时无FRR运行配置副作用 |
| [offline/deploy.sh](../../offline/deploy.sh) | 在RGW/ingress就绪后增加可单独续跑的可选BGP阶段；干跑不写配置、不改服务、不访问交换机；保持OSD人工安全闸门 |
| [offline/validate.sh](../../offline/validate.sh) | 参数冲突、接口/IP、TCP179及HAProxy可达性、已有FRR冲突、恢复运行时VIP已存在的幂等识别；不要因VIP正在被本集群合法持有就判空闲检查失败 |
| [offline/verify.sh](../../offline/verify.sh) | 分别报告本机健康与发布就绪、交换机未配置的pending、真实端到端PASS；BGP Active不能冒充完整成功，计划外路由必须拒绝 |
| [build/build-bundle.sh](../../build/build-bundle.sh) | 当前只复制offline/docs并计算这些目录的SHA256；需纳入新的Python/模板/服务资源，以及需要交付的doc材料；更新SHA256SUMS覆盖范围 |
| `deploy.sh`远端分发 | 当前主要复制offline/*.sh、配置及packages/images列表；必须显式分发新增*.py、systemd模板和其他资源，并保持SHA256/版本一致 |
| [docs/oneclick.md](../../docs/oneclick.md)、[docs/runbook-3node.md](../../docs/runbook-3node.md) | 记录新参数、交换机人工步骤、分阶段等待与恢复、验证范围、版本与包哈希 |

以上为后续任务，不表示这些生产脚本已经改好。

## 实现必须保留的行为

1. 默认关闭可选BGP模式；已有非BGP的一键部署行为和OSD安全确认保持兼容。已有运行Ceph只增量接入，不能重新清盘。
2. 仅修改目标节点业务接口的ARP项和自己拥有的dummy，不移动管理地址，不改物理宿主机、网桥、VLAN、默认路由、MTU或SR-IOV。
3. FRR出向精确允许一个VIP/32、入向全拒绝。磁盘配置不固化健康所有者的network语句；健康失败/停止撤销，重启后先健康再发布。
4. 本例Ubuntu自动启动zebra/staticd，仅bgpd=yes，bfdd=no。native FRR与systemd校验通过再启用服务。存在他人FRR配置时不直接覆盖。
5. 健康检测不要把匿名根目录GET、固定frontend/backend名、随机daemon目录写成通用假设；路径变化和更严格S3认证策略需可配置处理，不能导出统计认证或keyring。
6. H3C先在AF enable peer再应用过滤；实例级ignore暂缓会话，完成过滤/route-limit后undo ignore。保留交换机命令人工执行，不自动save。
7. 单次TCP按流哈希，不要求严格50/50。两条BGP均撤回时可能回落到/24+VRRP，不能用“VIP必然不可达”判断健康撤路逻辑。
8. 远端sudo使用sudo -n，ssh读取关闭 stdin，cephadm shell使用</dev/null或DEVNULL；密钥、密码、stats认证只在现有安全访问链路中使用，不进git/日志。

## 后续 agent 的完成标准

- 增加参数、可选阶段和支持资源；重复执行、默认关闭、已有FRR冲突、安装/配置失败回退都可控。单独BGP阶段不触发OSD流程。
- 在干净Ubuntu24.04 amd64构建环境收齐依赖，离线APT使用本地仓库且不访问公网；重建完整deb索引、镜像/脚本清单、SHA256SUMS、tar及tar.sha256。
- 用新的版本/tag与构建提交标识生成新包，保留旧版本；不拿旧oneclick.1包名/哈希代表已集成BGP的新包。
- 验证新包能分发所有Python/模板/服务资源。运行真实干跑和必要回归，特别保留磁盘安全相关测试。
- 在授权实验节点验证开关关闭、健康发布/撤路恢复、ARP单主、双入口真实TCP分流及参数回退。未测项目明确pending，不使用本目录旧实验PASS替代新包验收。
- 如要发布GitHub Release，记录构建环境、依赖版本、源码提交、包SHA256与验证范围；按后续任务授权执行发布，不在本次文档交接中宣称已发布。

配置正确性和测试基线见本目录证据。下一步是修改上述生产脚本、重建并验证新离线包，而不是仅把reference文件复制到包里就宣称接入完成。
