# 本地运行手册

这是 k3d 演示的生命周期手册。云上节点、HA、OpenObserve、密钥、TLS 和恢复要求见
[`production-blueprint.md`](production-blueprint.md)；本手册的 port-forward、local-path
和单副本配置不应直接用于生产。

## 生命周期

```bash
make demo-up       # 创建或更新 k3d 集群并部署本地示例
make demo-verify   # 执行验收路径、CRUD 检查和遥测检查
make status   # 查看工作负载和 Gateway API 状态
make demo-down     # 停止端口转发并删除 gofr-demo k3d 集群
```

生产集群不使用本手册的本地生命周期命令。完成节点 SSH 安装后，使用
`make production-storage STORAGE_BACKEND=longhorn` 或
`make production-storage STORAGE_BACKEND=cloud-csi`，再使用
`make production-platform` 安装平台组件；完整前置条件见
[`production-blueprint.md`](production-blueprint.md)。

`make up` 默认使用 `MODE=k3d`，不会安装或修改宿主机上的 k3s systemd 服务。若要使用
已有的宿主机安装，请显式设置 `MODE=host-k3s`；对应的 `make down` 会移除该宿主机 k3s
安装，因此应把它视为具有破坏性的开发选项。

若默认端口已被其他服务占用，可覆盖转发端口和运行目录。应用入口的备用端口
`28080` 是本地业务入口；Collector 预览允许任意来源但仍要求独立的 Bearer token：

```bash
RUNTIME_DIR=.runtime-preview K3D_CLUSTER_NAME=cloud-native-preview \
APP_PORT=28080 KITE_PORT=28082 OPENOBSERVE_PORT=28083 \
PROMETHEUS_PORT=29091 COLLECTOR_HTTP_PORT=24318 \
PORT_FORWARD_ADDRESS=127.0.0.1 make up
```

`make verify` 和 `make down` 使用同一组变量运行；down 只删除指定 k3d 集群并停止
指定 `RUNTIME_DIR` 中记录的转发进程。

## 访问地址

| 入口 | 本地地址 |
| --- | --- |
| 应用 Gateway | <http://127.0.0.1:8080>（Cilium Gateway） |
| Kite | <http://127.0.0.1:18080> |
| Prometheus | <http://127.0.0.1:19090> |
| OpenObserve UI/API | <http://localhost:18081> |
| Collector OTLP HTTP（调试） | <http://127.0.0.1:14318> |

OpenObserve 使用 Basic Auth；本地默认账号由 `OPENOBSERVE_EMAIL` 和
`OPENOBSERVE_PASSWORD` 提供，首次启动时写入本地 PVC。

本地启动会以 demo profile 同步三个 Dashboard：`K3s Cluster Overview`、`K3s Workloads &
Autoscaling` 和 `K3s Observability Pipeline`。生产默认是 core profile，只同步集群和
观测管道视图；把 OpenObserve 地址和凭据放在外部 Secret 后运行
`make observability-dashboards`。清单位于 `infra/observability/dashboards/`，脚本会按
标题幂等更新，并根据实际 stream 自动裁剪未接入组件的面板。

项目只负责名为 `gofr-demo` 的 k3d 集群以及上表中的端口转发。`make down` 只删除这些
资源，刻意不会停止无关的 Docker 容器或宿主机服务，因此在同时运行其他项目的开发工作站
上也可以安全清理。

## 验收矩阵

`make verify` 会检查以下契约：

1. Kubernetes 指标、Cilium 健康状态和 Gateway API 条件。
2. Cilium Envoy 数据面、应用/数据/可观测性工作负载和 HPA/KEDA。
3. Kite 与 Prometheus 的可用性。
4. 通过 Gateway 完成 Web 交付以及 catalog/order CRUD。
5. GoFr Prometheus 指标和 Collector 汇聚的 OpenTelemetry 信号。
6. 浏览器 OTLP 的 CORS、未授权拒绝、受限密钥认证和 Prometheus recording rule。

`make verify` 完成后可以使用以下 PromQL：

```promql
gofr:http_responses:rate5m
gofr:http_response_duration_seconds:p95
sum by (operation, result) (rate(catalog_cache_operations_total[5m]))
```

脚本会创建临时验收端口转发，并在退出时清理。`make up` 创建的持久端口转发会一直保留，
直到执行 `make down`。

## 故障排查

- 先检查 `kubectl get pods -A` 和 `kubectl -n gofr-demo get events --sort-by=.lastTimestamp`。
- 执行 `make logs` 查看 Cilium、orders 和 catalog 日志。
- 执行 `make network-status`，区分 Cilium 问题和 Gateway 问题。
- 如果上一次运行被中断，先执行一次 `make down` 并确认端口已释放，再执行 `make up`。
- 当镜像或 chart 下载必须经过本地代理时设置 `PROXY_URL`；只有 Docker 容器能够访问该
  代理时才设置 `NODE_PROXY_URL`。
