# 稳定态分流验证与后续新包验收

## 已取得的结果

[split-result.json](evidence/split-result.json)：64次独立TCP请求全部HTTP200/S3 XML，VM41命中27个、VM42命中37个，真实源端口无缺失和重复。两个入口捕获的二层源MAC是Leaf网关`0c:27:79:2f:b5:a4`。VM40临时路由和accept_redirects恢复，两台BGP及入口健康后检查通过。

原始响应、入口元数据：[probe.json](evidence/probe.json)、[capture-41.json](evidence/capture-41.json)、[capture-42.json](evidence/capture-42.json)。只记录IP、端口、SYN序列号、MAC、TTL、时间及响应状态，不含报文payload或认证值。

后续agent可在仓库根目录**只做离线证据复核**，不连接实验室：

```bash
python3 doc/s3-vip-bgp-20261027/reference/analyze_split.py \
  --probe doc/s3-vip-bgp-20261027/evidence/probe.json \
  --left doc/s3-vip-bgp-20261027/evidence/capture-41.json \
  --right doc/s3-vip-bgp-20261027/evidence/capture-42.json \
  --output /tmp/s3-vip-bgp-evidence-result.json
```

这只证明历史证据一致，不能替代新离线包安装后验收。分析器在Windows同样可运行，输出路径改为本机临时文件即可。

## 新包现场测试流程

1. 前置只读核对：Leaf两个Established，各收一个VIP/32，RIB及FIB均有两个可用下一跳；两台VM只发/32、收0条；HAProxy/RGW健康。检查开关关闭时不意外启用FRR。
2. 用一台独立实验源（本例VM40），临时添加精确VIP/32经Leaf路由；保留原路由和接口accept_redirects值，临时关闭该源接口redirect接收，避免同接口ICMP redirect使请求绕过Leaf。只动测试源VM，不动物理主机。
3. 同时在两个入口启动被动抓取，必须等待两个socket绑定并显式报告READY后才启动探测；给每轮一致的run_id，证据放新目录。
4. 客户端生成64次独立TCP GET，每次显式建立/关闭连接、记录真实源端口，禁用代理/自动重试/重定向，低频、有总超时。健康GET不等同于签名对象读写。
5. 捕获来自该测试源、目的VIP前端端口的入站SYN：目的MAC为本入口VM，源MAC为Leaf网关。排除后端8080请求、ACK及非本轮客户端。
6. 两个入口都必须命中至少一个测试源端口，两组无重叠，合并完整覆盖64个请求，全部响应正常；不要求严格各50%。
7. finally清理本轮临时/32并恢复接口原值；再核对ARP单主、BGP、入口和Ceph健康。异常退出也需明确记录清理状态。
8. 稳定态通过后才做单入口撤路测试：一次只撤回一个前缀，观察Leaf剩余单下一跳、新连接成功，再恢复双路径；不停止Ceph、不关物理网卡。已有TCP连接可能重置，不承诺状态迁移。

纯目标VM参考：[capture_ingress_vm.py](reference/capture_ingress_vm.py)、[routed_probe_vm40.py](reference/routed_probe_vm40.py)、[analyze_split.py](reference/analyze_split.py)。这些保留原实验hostname/IP保护，需参数化并接入新工具，不能直接用于其他节点。原工作站控制器`run_split_test.py`位于交接说明的原工作区，使用已批准的`.22`跳板；它不是本仓库offline运行依赖。后续实现应沿用显式READY屏障，不依赖人工延迟。

## 已修复的测试时序问题

旧三窗口手动操作在分别输入密码时耗尽了先启动抓取的60秒窗口：VM41比探测早57.378秒开始，比探测结束早3.976秒结束，仅命中9个连接；VM42命中34个，共43/64、缺21个，见[原失败诊断](evidence/failed-manual-window.json)。

该轮HTTP全成功也不能改判为分流完整通过。后续同步流程先确认两边READY，再发探测，成功得到27/37且完整64个。分析器保留完整性检查，失败时输出窗口、缺失和重复端口；新格式run_id不一致也拒绝通过。原工作站修复通过9项离线测试及上述现场重测。

## 验收范围

已证明这套手工接入配置的稳定态入口分流；尚未证明新的一键包实现、其他发行版、重新部署后动态发现、重启持久化、Leaf故障收敛、性能或签名S3对象读写。这些按新包功能范围补测并记录，不使用本次历史PASS作为替代。
