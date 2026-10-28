# 监控栈 + Dashboard（离线，默认部署）

`deploy.sh` 阶段 **monitoring**（在 `vip` 之后、`verify` 之前）= `offline/setup-monitoring.sh`。
已部署的老集群补装：换 oneclick.3+ 离线包 → node1 `./install-node.sh --verify-payload`（把新镜像推进本地 registry）→ `./deploy.sh --only monitoring` → `./verify.sh`。

## 镜像（全部来自 node1 本地 registry）
与 Ceph v20.2.4 `src/python-common/ceph/cephadm/images.py`（DefaultImages）一致：

| 服务 | 上游镜像 | 本地 registry | mgr 配置键 |
|---|---|---|---|
| prometheus | `quay.io/prometheus/prometheus:v3.6.0` | `<node1>:5000/prometheus/prometheus:v3.6.0` | `mgr/cephadm/container_image_prometheus` |
| alertmanager | `quay.io/prometheus/alertmanager:v0.28.1` | `<node1>:5000/prometheus/alertmanager:v0.28.1` | `mgr/cephadm/container_image_alertmanager` |
| node-exporter | `quay.io/prometheus/node-exporter:v1.9.1` | `<node1>:5000/prometheus/node-exporter:v1.9.1` | `mgr/cephadm/container_image_node_exporter` |
| grafana | `quay.io/ceph/grafana:12.3.1` | `<node1>:5000/ceph/grafana:12.3.1` | `mgr/cephadm/container_image_grafana` |
| ceph-exporter | 复用 ceph 主镜像 `ceph/ceph:v20.2.4` | — | `container_image`（全局） |

`install-node.sh`（node1）按 `images.list` 逐个 `podman load` → tag → push 到本地 registry；`bootstrap.sh` 与 `setup-monitoring.sh` 都设置上面 4 个键。
`cephadm bootstrap` 仍带 `--skip-monitoring-stack --skip-dashboard`：否则 bootstrap 会在这些键生效前去 quay.io 拉镜像（离线必失败），所以监控移到后面的独立阶段。

## 部署内容（`cluster.conf`）
| 变量 | 默认 | 说明 |
|---|---|---|
| `ENABLE_MONITORING` | 1 | ceph-exporter + node-exporter（每台主机）、prometheus、alertmanager、grafana；启用 mgr `prometheus` 模块 |
| `ENABLE_ALERTMANAGER` | 1 | 0 = 不部署 alertmanager |
| `MONITORING_HOSTS` | `()` | prometheus/alertmanager/grafana 放置；`()` = `count: 1` |
| `PROMETHEUS_RETENTION_TIME` | `15d` | 单位 y/w/d/h/m/s |
| `PROMETHEUS_RETENTION_SIZE` | `0` | 0 = 不限；如 `50GB` |
| `ENABLE_DASHBOARD` | 1 | HTTPS，端口 `DASHBOARD_PORT`（8443） |
| `DASHBOARD_CERT` / `DASHBOARD_KEY` | 空 | 两个都给 = 用自有证书（经 stdin 导入）；都空 = `ceph dashboard create-self-signed-cert`（已存证书则保留） |
| `DASHBOARD_ADMIN_USER` | `admin` | administrator 角色 |
| `DASHBOARD_ADMIN_PASSWORD_FILE` | `/etc/fast-deploy/dashboard-admin.pass` | 读第一行；不存在则生成 24 位随机密码写入（600）。**不打印、不进命令行**，经 stdin 传给 `ac-user-create`。用户已存在时不改密码，`DASHBOARD_RESET_PASSWORD=1` 才按文件重置 |
| `GRAFANA_FRONTEND_API_URL` | 空 | 浏览器访问 Grafana 的地址（`ceph dashboard set-grafana-frontend-api-url`），空 = cephadm 自动值 |
| `GRAFANA_API_SSL_VERIFY` | `False` | Grafana 为 cephadm 自签证书时须 False |
| `GRAFANA_ADMIN_PASSWORD_FILE` | 空 | 可选：Grafana `initial_admin_password`（写入临时 600 spec，经 stdin `orch apply`）；空 = cephadm 默认（匿名只读） |
| `SD_PORT` | 8765 | `mgr/cephadm/service_discovery_port` |

查看密码：`sudo cat /etc/fast-deploy/dashboard-admin.pass`（只在 node1）。

## 告警：只导出，不外发
按要求**不配置任何 webhook / SMTP / 外部接收器**。告警规则在内置 Prometheus 中评估，Dashboard 通过 alertmanager 显示；对外的唯一出口是**指标端点**，由外部 Prometheus/监控平台来采集。
`mgr/cephadm/secure_monitoring_stack` 保持默认 `false`（端点为明文 HTTP、无认证）；若现场改成 true，脚本会告警，外部采集需 TLS + basic auth（`ceph orch sd dump cert` 取根证书）。

## 端口（需对外部采集端放通）
| 端口 | 服务 | 所在 | 路径 |
|---|---|---|---|
| 9283 | mgr prometheus 模块（集群级指标，只有 active mgr 有数据） | 每个 mgr 主机 | `/metrics` |
| 9926 | ceph-exporter（daemon perf counters） | 每台主机 | `/metrics` |
| 9100 | node-exporter（主机指标） | 每台主机 | `/metrics` |
| 9095 | 内置 prometheus | `MONITORING_HOSTS` | `/api/v1/...`、`/federate` |
| 9093 | alertmanager | `MONITORING_HOSTS` | `/api/v2/alerts` |
| 3000 | grafana（https） | `MONITORING_HOSTS` | — |
| 8443 | dashboard（https） | active mgr | — |
| 8765 | cephadm 服务发现（http_sd，active mgr） | mgr 主机 | `/sd/prometheus/sd-config?service=<svc>` |

`bootstrap` 使用 `--skip-firewalld`；若现场开启了主机防火墙，需自行放通上述端口。
svc 可取：`mgr-prometheus`、`ceph-exporter`、`node-exporter`、`alertmanager`、`haproxy`（ingress）。

## 外部 Prometheus 采集示例
服务发现只在 **active mgr** 上应答：把所有 mgr 主机都写上，备 mgr 的 URL 报错不影响其它。
注意：`service=mgr-prometheus` 返回的目标是**主机名**（实测 `[{"targets": ["node2:9283"]}]`），外部 Prometheus 必须能解析 node1/node2/node3（DNS 或 /etc/hosts），否则用下面的静态目标；node-exporter / ceph-exporter 返回的是 IP。

```yaml
scrape_configs:
  - job_name: ceph                     # 集群级（health/pg/pool/osd...）
    honor_labels: true
    http_sd_configs:
      - url: http://10.250.0.11:8765/sd/prometheus/sd-config?service=mgr-prometheus
      - url: http://10.250.0.12:8765/sd/prometheus/sd-config?service=mgr-prometheus
      - url: http://10.250.0.13:8765/sd/prometheus/sd-config?service=mgr-prometheus
  - job_name: ceph-exporter
    honor_labels: true
    http_sd_configs:
      - url: http://10.250.0.11:8765/sd/prometheus/sd-config?service=ceph-exporter
      - url: http://10.250.0.12:8765/sd/prometheus/sd-config?service=ceph-exporter
  - job_name: node
    http_sd_configs:
      - url: http://10.250.0.11:8765/sd/prometheus/sd-config?service=node-exporter
      - url: http://10.250.0.12:8765/sd/prometheus/sd-config?service=node-exporter
```

不想依赖服务发现时用静态目标（mgr 9283 三台都写，只有 active 返回数据）：

```yaml
  - job_name: ceph-static
    honor_labels: true
    static_configs:
      - targets: ['10.250.0.11:9283', '10.250.0.12:9283', '10.250.0.13:9283']
  - job_name: ceph-exporter-static
    honor_labels: true
    static_configs:
      - targets: ['10.250.0.11:9926', '10.250.0.12:9926', '10.250.0.13:9926']
  - job_name: node-static
    static_configs:
      - targets: ['10.250.0.11:9100', '10.250.0.12:9100', '10.250.0.13:9100']
```

或者从内置 Prometheus 联邦拉取（含已计算的告警 `ALERTS`）：

```yaml
  - job_name: ceph-federate
    honor_labels: true
    metrics_path: /federate
    params: { 'match[]': ['{job=~".+"}', 'ALERTS'] }
    static_configs: [ { targets: ['10.250.0.11:9095'] } ]
```

自查：`curl -s http://<node>:9926/metrics | grep -c ^ceph_`、`curl -s http://<mgr>:8765/sd/prometheus/sd-config?service=ceph-exporter`。

## verify.sh 检查项
最多等 `MONITORING_WAIT`（默认 300 s）直到 `ceph orch ls` 中 ceph-exporter/node-exporter/prometheus/alertmanager/grafana 全部 running==size；node1 `:9926/metrics` 有 `ceph_*`；active mgr `:9283/metrics` 有 `ceph_health_status`；`:8765` 服务发现返回 ceph-exporter 目标；prometheus `:9095/-/ready`；打印 Dashboard URL（`ceph mgr services`）并 `curl -k` 期待 200。任一失败 → verify 失败。

## 关闭
`ENABLE_MONITORING=0`（只要 dashboard）/ `ENABLE_DASHBOARD=0`。已部署的服务不会被脚本删除；需要时人工 `ceph orch rm prometheus` 等。
