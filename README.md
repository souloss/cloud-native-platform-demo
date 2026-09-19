# Cloud Native Signal Forge

一个可在本地运行、按生产边界组织的云原生演示平台：用 k3d 承载 k3s，
用 Cilium 提供网络与流量可见性，用 Envoy Gateway 统一入口，用 GoFr
微服务演示弹性扩缩，并用 OpenTelemetry、Prometheus、HyperDX 和 Kite
串起从业务请求到集群运维的完整观测路径。

项目仓库建议使用 `cloud-native-signal-forge` 作为 slug；现有 Kubernetes
namespace、镜像和服务名保留 `gofr-demo` / `k3s-gofr-*`，便于兼容已有本地
演示环境和脚本。

架构分层与请求路径见 [`docs/architecture.md`](docs/architecture.md)，日常
启动、验收、排障和停止步骤见 [`docs/runbook.md`](docs/runbook.md)。

这是一个可在 Linux 本机运行的全链路示例：

```
Browser (Vue + HyperDX session replay) -> Envoy Gateway API -> web / orders / catalog
                                           |                    -> PostgreSQL / MySQL / Redis
                                           +-- Cilium CNI/Hubble: pod networking and flow visibility
                                           +-- OpenTelemetry Collector -> HyperDX v2
```

当前默认版本（均可通过环境变量覆盖）：k3s `v1.37.0+k3s1`、Cilium `1.20.2`、Envoy Gateway `v1.9.1`、Gateway API `v1.6.1` standard channel、GoFr `v1.58.0`；HyperDX 使用 `hyperdx/hyperdx-all-in-one:latest`（v2），浏览器 SDK 为 `0.26.0`。

## 前置条件

- Linux amd64/arm64，4 CPU、8 GB 内存以上
- Docker daemon（构建镜像时使用）
- Docker、`curl`、`kubectl`；默认脚本会用 k3d 创建 Docker 化 k3s
- Helm 3（缺失时启动脚本会自动安装）
- 本地模式不需要 HyperDX Cloud API key；切换到 Cloud 模式时才需要配置 key

## 启动

```bash
make up
```

根目录 `Makefile` 是日常入口：`make up`、`make verify`、`make status`、`make resource-status`、`make network-status`、`make check`、`make test`、`make frontend-build`、`make load-test` 和 `make down` 分别调用对应脚本或工具命令。需要查看具体实现时，再阅读 `scripts/*.sh`。

默认 `HYPERDX_MODE=local`，HyperDX v2 all-in-one 会部署到当前 Kubernetes 集群，并通过 `http://localhost:18081` 暴露 UI/API；本机还会转发 OTLP gRPC 到 `14317`、OTLP HTTP 到 `14318`。集群内地址分别是 `hyperdx.gofr-demo.svc.cluster.local:4317/4318`。如果要继续使用 HyperDX Cloud，启动前设置 `HYPERDX_MODE=cloud`、`HYPERDX_API_KEY` 和 `HYPERDX_OTLP_ENDPOINT`。

默认使用 k3d 创建一个包含 1 个 server、2 个 agent 的 Docker 化 k3s 集群，不修改宿主机 systemd；可用 `MODE=host-k3s ./scripts/up.sh` 复用宿主机 k3s。k3d 创建时关闭 Flannel、k3s network-policy、Traefik 和 ServiceLB，随后安装 Cilium（CNI、网络策略、Hubble 与可选 eBPF datapath）与 Envoy Gateway（Gateway API controller）；默认保留 k3s kube-proxy，以兼容 k3d 的系统服务。脚本支持 `PROXY_URL=http://127.0.0.1:7890`（默认值）拉取 k3d、Kubernetes、Cilium、Envoy 和应用镜像。它会安装 Gateway API CRD、构建并导入镜像、部署清单，并等待 Cilium、Envoy Gateway、Gateway、HTTPRoute 和 Pod 就绪。它会把 Envoy Gateway 的 ClusterIP service 转发到 `127.0.0.1:8080`：

```bash
curl http://127.0.0.1:8080/api/orders
open http://127.0.0.1:8080/
```

启动脚本还会用 `kubectl port-forward` 暴露本地入口（不创建公网 LoadBalancer）：

- 应用入口：<http://127.0.0.1:8080>（Envoy Gateway -> web/orders/catalog）
- Kite Dashboard：<http://127.0.0.1:18080>。本地演示默认开启匿名入口，并预置 `admin` / `kite-admin` 账号；首次打开即可进入 Gateways、HTTPRoutes、Deployments、Pods、HPA 和事件页面。演示 Gateway 位于 `gofr-demo` namespace，切换该 namespace 即可看到 `public`。Kite SQLite 数据持久化在 k3d 的 `kite-storage` PVC 中。
- Prometheus：<http://127.0.0.1:19090>
- HyperDX v2 UI/API：<http://localhost:18081>（认证 Cookie 和查询 API 使用此 origin，请不要改成 `127.0.0.1`）
- HyperDX OTLP HTTP（浏览器 traces、logs、session replay）：<http://127.0.0.1:14318>
- HyperDX OTLP gRPC：`127.0.0.1:14317`

### 环境地址与登录信息

| 组件 | 地址 | 账号 | 密码/说明 |
| --- | --- | --- | --- |
| 业务入口 | <http://127.0.0.1:8080> | 不需要 | Vue + Gateway API |
| Kite | <http://127.0.0.1:18080> | `admin` | `kite-admin` |
| HyperDX v2 | <http://localhost:18081> | `demo@signal-forge.local` | `SignalForge#2026` |
| Prometheus | <http://127.0.0.1:19090> | 不需要 | PromQL 查询页面 |
| PostgreSQL | 集群内 `postgres.gofr-demo.svc.cluster.local:5432` | `demo` | `demo-password` |
| MySQL | 集群内 `mysql.gofr-demo.svc.cluster.local:3306` | `demo` | `demo-password` |
| Redis | 集群内 `redis.gofr-demo.svc.cluster.local:6379` | 不需要 | 无认证 |

以上密码只适用于本机教学环境；本地模式首次 `make up` 会通过 HyperDX 注册 API 创建该账号，已有 HyperDX PVC 时不会覆盖现有用户。生产环境应通过 Secret 注入并立即替换；HyperDX 登录后建议在用户设置中再次修改密码。可在启动前用 `HYPERDX_DEMO_EMAIL` 和 `HYPERDX_DEMO_PASSWORD` 覆盖本地演示账号。

WSL2 与 Windows：脚本使用 `kubectl port-forward --address 0.0.0.0`。业务、Kite、Prometheus 和 OTLP 端口可在 WSL localhost 转发不可用时改用 `hostname -I` 返回的 WSL IP。HyperDX UI 必须使用 <http://localhost:18081>，因为本地认证 Cookie 与 CORS origin 明确绑定到 `localhost`；用 `127.0.0.1` 或 WSL IP 打开会导致查询 API 显示 `Failed to fetch`。不要将这些端口暴露到不可信网络。
Vue 会根据当前浏览器访问应用时的 hostname 自动选择 HyperDX OTLP HTTP `:14318`，所以从 Windows 使用 WSL IP 时 session replay 仍会回传到同一 WSL 实例；如需固定地址，可在启动前设置 `VITE_HYPERDX_URL=http://<WSL-IP>:14318`。

示例数据库凭据：PostgreSQL service `postgres.gofr-demo.svc.cluster.local:5432`，MySQL service `mysql.gofr-demo.svc.cluster.local:3306`，Redis service `redis.gofr-demo.svc.cluster.local:6379`；PostgreSQL/MySQL database 和 user 均为 `demo`，密码为 `demo-password`。`orders` 使用 PostgreSQL 保存订单并调用 `catalog`，`catalog` 使用 MySQL 保存商品并用 Redis 缓存单项读取，因此一次订单请求会实际访问 PostgreSQL、MySQL 和 Redis。外部业务入口统一走 Gateway API：`/`、`/api/orders`、`/api/catalog`；数据库、Collector 和运维 UI 保持集群内或 port-forward，不通过业务 Gateway 暴露。
Kite 的匿名模式和 `admin` / `kite-admin` 仅用于 localhost 演示；生产环境应关闭匿名模式、替换 JWT/加密密钥并通过 Secret 管理管理员凭据。

验证和清理：

```bash
make verify
make down
```

提交前建议运行 `make check`。它会检查 shell 语法、Git 空白错误、Go
测试/静态检查/构建和前端生产构建；CI 对同一组本地质量门禁执行验证。

`verify.sh` 检查 Gateway API CRD、GatewayClass、Gateway、HTTPRoute、Cilium agent、Envoy Gateway 双副本、MySQL/Redis/应用 Deployment、HPA、Kite、HyperDX、CRUD 请求和 GoFr metrics。`down.sh` 默认删除 k3d 集群；`MODE=host-k3s ./scripts/down.sh` 才会卸载宿主机 k3s。

## HyperDX v2 与 session replay

后端 GoFr 使用 OTLP/gRPC 发往集群内 Collector，Collector 使用 HyperDX v2 OTLP/HTTP endpoint。默认：

```bash
export HYPERDX_API_KEY=...
export HYPERDX_OTLP_ENDPOINT=https://in-otel.hyperdx.io
export HYPERDX_API_VERSION=v2
```

本地模式使用上方表格中的 HyperDX 账号登录即可查看 Traces、Logs、Metrics 和 Session Replay。不要提交 API key；它由 Secret 注入。本地演示默认使用 `k3s-gofr-local-ingestion` 初始化 Collector 和 Vue browser SDK；生产环境应单独设置受限的 `VITE_HYPERDX_API_KEY`。切换到 Cloud 时再设置 `HYPERDX_MODE=cloud HYPERDX_API_KEY=your-key`。

前端显式开启 HyperDX session replay、console capture、完整网络请求捕获和 W3C trace propagation；页面中的 `Mark demo action` 按钮会生成带时间戳的 custom action，订单 CRUD 请求会进入同一个 browser-to-backend trace。演示页面提供明确的 Pause/Resume recording、Session ID 复制、错误反馈和删除确认，便于在 HyperDX Sessions 中直接查看完整操作过程。

完整演示顺序：1) 打开应用入口，页面默认开始 session replay；2) 点击 `Mark demo action`，页面会显示已记录时间，再到 HyperDX Sessions 查看当前会话；3) 在 Traces 按 `k3s-gofr-web`、`k3s-gofr-orders` 或 `k3s-gofr-catalog` 查看 browser → Envoy Gateway → orders → catalog → PostgreSQL/MySQL/Redis 链路，并在 Cilium/Hubble 中查看 Pod flow；4) 在 Prometheus 查询 `app_http_response_count`、`rate(app_http_response_count[5m])` 或 `up{job="gofr-services"}`；5) 运行 `./scripts/load-test.sh`，观察 `kubectl -n gofr-demo get hpa,pods -w` 中 orders 扩容；6) 在 Kite 查看 Gateway、Deployment、Pod、HPA 和事件；7) 查看 Cilium：`kubectl -n kube-system get pods -l k8s-app=cilium`。`Pause recording` / `Resume recording` 只控制当前浏览器会话的 recorder，不会删除已有回放。

HyperDX 的 SQL 编辑器必须遵守 ClickHouse 子句顺序：`FROM` → `WHERE` → `ORDER BY` → `LIMIT`。例如下面的查询可以直接粘贴到 Traces：

```sql
SELECT
  Timestamp,
  ServiceName,
  StatusCode,
  round(Duration / 1e6) AS DurationMs,
  SpanName
FROM default.otel_traces
WHERE Timestamp >= now() - INTERVAL 1 HOUR
  AND SpanName = 'POST /api/orders'
ORDER BY (toDateTime(Timestamp), Timestamp) DESC
LIMIT 200
```

`0 Results` 表示时间窗口内没有匹配 span；`Failed to fetch` 则通常表示查询请求失败。此前的示例把 `ORDER BY` 放在 `WHERE` 前，ClickHouse 会返回语法错误。`make verify` 会先产生一笔订单请求，再用正确的 SQL 验证 `POST /api/orders` 已写入 HyperDX。

## 本地开发

```bash
cd services
go mod tidy
go run ./catalog
go run ./orders
cd ../frontend/web && pnpm install && pnpm dev
```

`services/go.mod`、`services/go.sum` 和 `services/go.work` 都属于后端目录：当前仓库只有一个 Go module，workspace 文件放在 module 旁边可以让 `go test ./...`、`go vet ./...` 和 `go build ./...` 的作用域清晰一致。根目录 `Makefile` 只负责进入 `services/` 调用这些命令；基础设施、前端和脚本不放进后端 module，避免把 Kubernetes YAML 或 Node 依赖混入 Go module 的依赖图。

后端镜像构建上下文也保持在 `services/`：

```bash
docker build -f services/Dockerfile --build-arg SERVICE=catalog services
docker build -f services/Dockerfile --build-arg SERVICE=orders services
```

本地 `make up` 使用 `services/Dockerfile.runtime` 把宿主机编译出的二进制打包进运行时镜像；这样启动脚本不需要在 Docker build 阶段再次访问 Go module 下载源。

GoFr 默认 HTTP 端口是 8000、metrics 端口是 2121；本示例部署环境使用默认端口。GoFr 自动提供 `/.well-known/health`、`/.well-known/alive` 和 `/metrics`。

Envoy Gateway listener 使用 80，生成的 Envoy proxy Service 是 ClusterIP，因此本机 `8080:80` port-forward 对浏览器保持普通 HTTP 入口。Web Deployment 内的 Nginx 只监听 8080、提供 Vue 静态文件，`/api` 完全由 Gateway API 转发到 orders。

### 设计说明

- GoFr 自带 HTTP request tracing、structured logging、Prometheus metrics 和健康探针；通过 `TRACE_EXPORTER=otlp` 发到 Collector。
- `orders` 用 W3C `traceparent` 传播头调用 `catalog`，一次浏览器请求会形成 browser → gateway → orders → catalog 的 trace。
- Cilium 提供集群 CNI、网络策略、Hubble 和 eBPF datapath；当前 k3d 默认保留 kube-proxy，以确保 k3s 的 API、DNS 和 ClusterIP 在本机多节点环境稳定。`kubeProxyReplacement=false` 是兼容性选择，不代表 Cilium 不工作。
- Cilium 也支持 `kubeProxyReplacement=true`，但这不是对现有集群的热切换：必须重新创建 kube-proxy-free 集群，并同时验证 API server 可达性、NodePort/HostPort 和 Cilium socket-LB 设置。仅把 values 中的布尔值改成 `true` 会让当前 k3d profile 的系统服务失效，所以示例默认保留 `false`；生产环境可按 Cilium 的 kube-proxy replacement 专用集群方案单独启用并重新验收。
- Envoy Gateway 是实现 Gateway API 的 controller。`GatewayClass` 的 `controllerName` 固定为 `gateway.envoyproxy.io/gatewayclass-controller`。

## 目录

- `infra/k3s`：namespace 与 k3s 运行边界
- `infra/network`：Cilium values、Envoy Gateway values、GatewayClass/Gateway/HTTPRoute
- `infra/apps`：GoFr orders/catalog、Vue web 的 Deployment/Service，以及 HPA/PDB
- `infra/observability`：HyperDX Secret、OTel Collector、OTLP pipelines
- `infra/data`：Postgres PVC、Deployment 和 Service
- `infra/data/mysql-redis.yaml`：MySQL PVC、Redis、Deployment 和 Service
- `services`：独立 Go module（`go.mod`、`go.sum`、`go.work`、`Dockerfile`）与 catalog/orders 源码
- `frontend/web`：Vue + HyperDX v2 browser SDK + session replay
- `docs`：架构边界和本地运行手册
- `.github/workflows`：不依赖集群的持续集成质量门禁

Kite 使用官方 `kite-org/kite` Helm OCI chart；`infra/dashboard/kite.yaml` 开启本地匿名演示、稳定密钥、SQLite PVC，并通过配置文件自动注册 `in-cluster` 为默认集群。没有 Helm 时，`infra/dashboard/kite-fallback.yaml` 提供等价的 Secret、PVC、Deployment 和 Service，不再使用官方最小 `deploy/install.yaml`，因此资源页不会因没有登录态或当前集群上下文而显示 `Failed to fetch`。Kite 和 Prometheus 都只通过 port-forward 暴露。

## 弹性演示

启动后运行 `./scripts/load-test.sh`（需要 `hey`）。另一个终端执行 `kubectl -n gofr-demo get hpa,pods -w`，可以看到 orders 从 2 副本扩展，Gateway 和 web/catalog 也能在多 Pod 间路由。HPA 依赖 k3s 自带 metrics-server；PDB 保证滚动维护时至少保留一个可用副本。
