# 实验记录索引

成功轮次：`split-sync-20261027T023814Z-0f08e7`，2026-10-27 UTC。结果文件移除了原工作站绝对目录字段，其余验证字段保留；probe/capture保留原VM执行结果wrapper，stderr中的CAPTURE_READY是同步就绪标志。

- [split-result.json](split-result.json)：64/64、VM41/42为27/37，无缺失或重复、测试源已恢复、BGP/入口健康后检查通过。
- [probe.json](probe.json)：每次HTTP状态、S3 XML标记、客户端源端口、临时路由与恢复值。
- [capture-41.json](capture-41.json)、[capture-42.json](capture-42.json)：各入口元数据与匹配SYN。
- [failed-manual-window.json](failed-manual-window.json)：旧手动流程漏抓21个连接，保持FAIL，不与成功轮次混用。

这里不包含原始pcap、密码、私钥、keyring、S3密钥、HAProxy统计认证值或离线deb二进制。
