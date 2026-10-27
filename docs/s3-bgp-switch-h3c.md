# S3 BGP/ECMP：H3C Leaf 侧（人工执行）

**脚本从不登录交换机。** 以下命令由网络管理员在 H3C（实验型号 R6715 系列 Comware 7）上手工执行，不自动 `save`。
来源：`doc/s3-vip-bgp-20261027/switch/*.txt`（实验已成功的配置）。

## 参数对应
| 交换机 | cluster.conf | 实验值 |
|---|---|---|
| BGP AS | `S3_BGP_PEER_ASN` | 65000 |
| router-id / 节点的 peer 地址 | `S3_BGP_PEER_IP` | 10.11.4.1 |
| 对端（每台 RGW 节点业务 IP） | `NODE_IPS` 中 `S3_BGP_HOSTS` | 10.11.4.41、10.11.4.42 |
| 对端 AS | `S3_BGP_LOCAL_ASN` | 65050 |
| VIP/32 | `S3_BGP_VIP`（= `RGW_VIP`） | 10.11.4.50 |
| 定时器 | `S3_BGP_KEEPALIVE` / `S3_BGP_HOLD` | 3 / 9 |
| ECMP 路数 | `S3_BGP_HOSTS` 个数 | 2 |

注意 prefix-list 方向与节点侧相反：交换机 **import** 只允许 VIP/32（`S3VIP50-IN`），**export** 全拒绝（`S3VIP50-OUT`），即不向节点发任何路由；`route-limit 1` 防止节点误发多条。

## 应用（顺序重要）
先用实例级 `peer X ignore` 暂停会话 → 在 AF 里 **先 `peer enable` 再挂过滤** → `route-limit` → 最后 `undo peer ignore`。
否则会话可能在过滤生效前建立。
```
system-view
ip prefix-list S3VIP50-IN index 10 permit 10.11.4.50 32
ip prefix-list S3VIP50-OUT index 10 deny 0.0.0.0 0 less-equal 32
bgp 65000
 router-id 10.11.4.1
 peer 10.11.4.41 as-number 65050
 peer 10.11.4.42 as-number 65050
 peer 10.11.4.41 timer keepalive 3 hold 9
 peer 10.11.4.42 timer keepalive 3 hold 9
 peer 10.11.4.41 ignore
 peer 10.11.4.42 ignore
 address-family ipv4 unicast
  balance ebgp 2
  peer 10.11.4.41 enable
  peer 10.11.4.42 enable
  peer 10.11.4.41 prefix-list S3VIP50-IN import
  peer 10.11.4.41 prefix-list S3VIP50-OUT export
  peer 10.11.4.42 prefix-list S3VIP50-IN import
  peer 10.11.4.42 prefix-list S3VIP50-OUT export
  peer 10.11.4.41 route-limit 1
  peer 10.11.4.42 route-limit 1
 quit
 undo peer 10.11.4.41 ignore
 undo peer 10.11.4.42 ignore
return
```
- 已有 `bgp <AS>` 实例时**不要**重复 `router-id`，只加 peer 部分；若该实例已有其它 peer/策略，先与网络管理员确认不冲突。
- 第三台入口：增加对应 `peer` 行，`balance ebgp 3`。
- 中途中断（例如 AF 未配完）时的续做顺序（实验 `resume-peer-order.txt`）：
```
quit
peer 10.11.4.41 ignore
peer 10.11.4.42 ignore
address-family ipv4 unicast
 peer 10.11.4.41 enable
 peer 10.11.4.42 enable
 peer 10.11.4.41 prefix-list S3VIP50-IN import
 peer 10.11.4.41 prefix-list S3VIP50-OUT export
 peer 10.11.4.42 prefix-list S3VIP50-IN import
 peer 10.11.4.42 prefix-list S3VIP50-OUT export
 peer 10.11.4.41 route-limit 1
 peer 10.11.4.42 route-limit 1
quit
undo peer 10.11.4.41 ignore
undo peer 10.11.4.42 ignore
return
```
确认无误后由管理员自行决定是否 `save`。

## 检查
```
display current-configuration configuration bgp
display bgp peer ipv4
display bgp routing-table ipv4 unicast 10.11.4.50 32
display ip routing-table 10.11.4.50 32
display fib 10.11.4.50
display ip prefix-list name S3VIP50-IN
display ip prefix-list name S3VIP50-OUT
```
期望：两个 peer `Established`；`10.11.4.50/32` 有两条 BGP 路由、路由表/FIB 两个下一跳（.41/.42）；`S3VIP50-IN` 有 Permitted 计数、`S3VIP50-OUT` 只有 Denied。
实验时的运行配置快照（对照用）：
```
bgp 65000
 router-id 10.11.4.1
 peer 10.11.4.41 as-number 65050
 peer 10.11.4.41 timer keepalive 3 hold 9
 peer 10.11.4.42 as-number 65050
 peer 10.11.4.42 timer keepalive 3 hold 9
 #
 address-family ipv4 unicast
  balance ebgp 2
  peer 10.11.4.41 enable
  peer 10.11.4.41 prefix-list S3VIP50-IN import
  peer 10.11.4.41 prefix-list S3VIP50-OUT export
  peer 10.11.4.41 route-limit 1
  peer 10.11.4.42 enable
  peer 10.11.4.42 prefix-list S3VIP50-IN import
  peer 10.11.4.42 prefix-list S3VIP50-OUT export
  peer 10.11.4.42 route-limit 1
```
节点侧对照：`sudo vtysh -c 'show bgp summary'`、`sudo ./verify.sh`（node1）。
单台维护：节点上 `touch /run/fast-deploy-s3-bgp.disabled`，交换机 `display bgp routing-table ipv4 unicast 10.11.4.50 32` 应只剩另一下一跳。

## 回退
先交换机、后节点（`./teardown-s3-bgp.sh`）：
```
system-view
bgp 65000
 address-family ipv4 unicast
  undo peer 10.11.4.41 enable
  undo peer 10.11.4.42 enable
 quit
 undo peer 10.11.4.41
 undo peer 10.11.4.42
quit
undo ip prefix-list S3VIP50-IN
undo ip prefix-list S3VIP50-OUT
return
```
若 `bgp 65000` 实例是为本功能新建且无其它 peer，可由管理员另行决定是否 `undo bgp`。回退后同 VLAN 与经 Leaf 的流量都走 `/24` 直连 + VRRP 主（原 VIP 路径）。
