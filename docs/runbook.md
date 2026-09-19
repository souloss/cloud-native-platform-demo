# 本地运行手册

## 生命周期

```bash
make up       # 创建或更新 k3d 集群并部署所有层
make verify   # 执行验收路径、CRUD 检查和遥测检查
make status   # 查看工作负载和 Gateway API 状态
make down     # 停止端口转发并删除 gofr-demo k3d 集群
```

`make up` 默认使用 `MODE=k3d`，不会安装或修改宿主机上的 k3s systemd 服务。若要使用
已有的宿主机安装，请显式设置 `MODE=host-k3s`；对应的 `make down` 会移除该宿主机 k3s
安装，因此应把它视为具有破坏性的开发选项。

## 访问地址

| 入口 | 本地地址 |
| --- | --- |
| 应用 Gateway | <http://127.0.0.1:8080> |
| Kite | <http://127.0.0.1:18080> |
| Prometheus | <http://127.0.0.1:19090> |
| HyperDX UI/API | <http://localhost:18081> |
| Collector OTLP HTTP（调试） | <http://127.0.0.1:14318> |

HyperDX UI/API 的本地认证 Cookie 和 CORS 来源域按 `localhost` 配置，因此访问它时必须
使用 `localhost`。

在全新的本地 HyperDX volume 中，`make up` 会根据 `HYPERDX_DEMO_EMAIL` 和
`HYPERDX_DEMO_PASSWORD` 创建演示账号；已有 volume 中的用户不会被修改。

项目只负责名为 `gofr-demo` 的 k3d 集群以及上表中的端口转发。`make down` 只删除这些
资源，刻意不会停止无关的 Docker 容器或宿主机服务，因此在同时运行其他项目的开发工作站
上也可以安全清理。

## 验收矩阵

`make verify` 会检查以下契约：

1. Kubernetes 指标、Cilium 健康状态和 Gateway API 条件。
2. Envoy 代理副本、应用/数据/可观测性工作负载和 HPA。
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
- 执行 `make logs` 查看 Envoy Gateway、orders 和 catalog 日志。
- 执行 `make network-status`，区分 Cilium 问题和 Gateway 问题。
- 如果上一次运行被中断，先执行一次 `make down` 并确认端口已释放，再执行 `make up`。
- 当镜像或 chart 下载必须经过本地代理时设置 `PROXY_URL`；只有 Docker 容器能够访问该
  代理时才设置 `NODE_PROXY_URL`。
