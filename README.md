# Cloud Native Platform Demo

云上生产蓝图（现有 Linux、仅 SSH、不可重装系统）见
[`docs/production-blueprint.md`](docs/production-blueprint.md)。该蓝图使用
K3s + Cilium Gateway API + KEDA + OpenTelemetry Operator + OpenObserve，并将
对象存储、PostgreSQL、NATS、TLS、密钥和备份作为生产前置条件。`make demo-up`
是隔离的本地 k3d 演示入口；`make production-platform` 和
`make production-storage` 面向已经完成节点准备的生产 K3s 集群。

一个可在本地运行、按生产边界组织的云原生平台演示：用 k3d 承载 k3s，
用 Cilium 提供网络、Gateway API 和流量可见性，用 GoFr
微服务演示弹性扩缩，并用 OpenTelemetry、Prometheus、OpenObserve 和 Kite
串起从业务请求到集群运维的完整观测路径。

仓库地址：<https://github.com/souloss/cloud-native-platform-demo>。
Kubernetes namespace、镜像和服务名保留 `gofr-demo` / `k3s-gofr-*`，作为
稳定的本地运行时标识，避免让演示项目名和基础设施资源名耦合。

架构分层与请求路径见 [`docs/architecture.md`](docs/architecture.md)，日常
启动、验收、排障和停止步骤见 [`docs/runbook.md`](docs/runbook.md)。

这是一个可在 Linux 本机运行的全链路示例：

```
浏览器（Vue + 会话回放） -> Cilium Gateway API -> web / orders / catalog
                              |                    -> PostgreSQL / MySQL / Redis
                              +-- OTLP/HTTP -> OpenTelemetry Collector -> OpenObserve v1.1.2
                              +-- Cilium CNI/Hubble：Pod 网络与流量可见性
```

当前默认版本（均可通过环境变量覆盖）：k3s `v1.37.2+k3s1`、Cilium `1.20.4`、Gateway API `v1.7.0` standard 通道、KEDA `2.21.0`、OTel Operator `0.162.0`；OpenObserve 固定为 `v1.1.2`，浏览器 SDK 版本由前端锁文件固定。

## 项目定位

这是一个可运行的云原生平台参考实现，不是单一微服务样例。它把入口治理、
服务间调用、数据访问、弹性策略和观测信号放在同一个可复现的本地环境中：

- **统一入口**：Cilium Gateway API，只暴露一个业务入口，内部服务保持 ClusterIP。
- **弹性与可用性**：应用多副本、滚动更新、PodDisruptionBudget、资源边界、启动/就绪/存活探针和 HPA。
- **统一观测**：GoFr 结构化日志、Prometheus 指标、OpenTelemetry 链路，以及经项目 Collector 接入的浏览器会话回放。
- **网络可见性**：Cilium CNI、Hubble/eBPF 数据路径和 Kite 集群资源视图。
- **本地可复现**：k3d 一键创建，不修改宿主机 systemd；`make verify` 验收从 Gateway 到持久化和遥测的完整路径。

工程边界、请求/信号路径和本地取舍见 [`docs/architecture.md`](docs/architecture.md)。

## 前置条件

- Linux amd64/arm64，4 CPU、8 GB 内存以上
- Docker 守护进程（构建镜像时使用）
- Docker、`curl`、`kubectl`；默认脚本会用 k3d 创建 Docker 化 k3s
- Helm 4.3.1（缺失时启动脚本会自动安装）
- 本地模式不需要 OpenObserve Cloud API 密钥；切换到 Cloud 模式时才需要配置密钥

## 启动

```bash
make up
```

根目录 `Makefile` 是日常入口：本地演示使用 `make demo-up`、`make demo-verify`、
`make demo-down`；生产平台使用 `make production-platform`，存储后端使用
`make production-storage`。`make up`、`make verify` 和 `make down` 保留为本地
演示兼容别名。需要查看具体实现时，再阅读 `scripts/*.sh`。

默认本地模式会部署 OpenObserve v1.1.2 一体化实例，并通过 `http://localhost:18081` 暴露 UI/API；浏览器 OTLP 统一经业务 Gateway 的 `/v1/traces`、`/v1/logs` 和 `/v1/metrics` 进入项目 Collector。集群内服务间链路使用 `gateway-collector.gofr-demo.svc.cluster.local:4317`，Collector 再转发到 OpenObserve。云端后端需要单独配置对应的 OTLP endpoint 和认证 Secret。

默认使用 k3d 创建一个包含 1 个 server、2 个 agent 的 Docker 化 k3s 集群，不修改宿主机 systemd；可用 `MODE=host-k3s ./scripts/up.sh` 复用宿主机 k3s。k3d 创建时关闭 Flannel、k3s network-policy、Traefik、ServiceLB 和 kube-proxy，随后安装 Cilium（CNI、Gateway API、Hubble 与 eBPF 数据路径）。脚本支持 `PROXY_URL=http://127.0.0.1:7890`（默认值）拉取 k3d、Kubernetes、Cilium 和应用镜像。它会安装 Gateway API CRD、构建并导入镜像、部署清单，并等待 Cilium、Gateway、HTTPRoute 和 Pod 就绪；本地入口通过 Cilium Gateway 的 NodePort 映射到 `127.0.0.1:8080`：

```bash
curl http://127.0.0.1:8080/api/orders
open http://127.0.0.1:8080/
```

启动脚本还会用 `kubectl port-forward` 暴露本地入口（不创建公网 LoadBalancer）：

- 应用入口：<http://127.0.0.1:8080>（Cilium Gateway -> web/orders/catalog）
- Kite 控制台：<http://127.0.0.1:18080>。本地演示默认开启匿名入口，并预置 `admin` / `kite-admin` 账号；首次打开即可进入 Gateways、HTTPRoutes、Deployments、Pods、HPA 和事件页面。演示 Gateway 位于 `gofr-demo` namespace，切换该 namespace 即可看到 `public`。Kite SQLite 数据持久化在 k3d 的 `kite-storage` PVC 中。
- Prometheus：<http://127.0.0.1:19090>
- OpenObserve v1.1.2 UI/API：<http://localhost:18081>（认证 Cookie 和查询 API 使用此来源域，请不要改成 `127.0.0.1`）
- OpenObserve Dashboard：`K3s Cluster Overview`、`K3s Workloads & Autoscaling`、`K3s Observability Pipeline`；本地 `make demo-up` 使用 demo profile，生产默认只同步 core profile，并按实际 stream 自动裁剪可选面板
- Collector OTLP HTTP（本地调试入口）：<http://127.0.0.1:14318>。浏览器默认走业务 Gateway，不需要直接访问此端口。

### 环境地址与登录信息

| 组件 | 地址 | 账号 | 密码/说明 |
| --- | --- | --- | --- |
| 业务入口 | <http://127.0.0.1:8080> | 不需要 | Vue + Gateway API |
| Kite | <http://127.0.0.1:18080> | `admin` | `kite-admin` |
| OpenObserve v1.1.2 | <http://localhost:18081> | `demo@cloud-native.local` | `CloudNative#2026` |
| Prometheus | <http://127.0.0.1:19090> | 不需要 | PromQL 查询页面 |
| PostgreSQL | 集群内 `postgres.gofr-demo.svc.cluster.local:5432` | `demo` | `demo-password` |
| MySQL | 集群内 `mysql.gofr-demo.svc.cluster.local:3306` | `demo` | `demo-password` |
| Redis | 集群内 `redis.gofr-demo.svc.cluster.local:6379` | 不需要 | 无认证 |

以上密码只适用于本机教学环境；本地模式首次 `make up` 会通过 OpenObserve 注册 API 创建该账号，已有 OpenObserve PVC 时不会覆盖现有用户。生产环境应通过 Secret 注入并立即替换；OpenObserve 登录后建议在用户设置中再次修改密码。可在启动前用 `OPENOBSERVE_DEMO_EMAIL` 和 `OPENOBSERVE_DEMO_PASSWORD` 覆盖本地演示账号。

生产环境只需要保留 K3s 内置 `metrics-server` 来服务 HPA，以及 OTel Collector 把指标写入
OpenObserve；OpenObserve 的 PromQL API 可供 KEDA 查询，因此 Prometheus Server 是可选的
兼容组件。若需要把版本化 Dashboard 应用到生产 OpenObserve，使用
`OPENOBSERVE_URL`、`OPENOBSERVE_EMAIL` 和 `OPENOBSERVE_PASSWORD` 执行
`make observability-dashboards`，不要把生产凭据写入 Dashboard JSON。生产默认 profile 是
`core`；只有部署了示例 GoFr 应用并明确设置
`OBSERVABILITY_DASHBOARDS_PROFILE=demo OBSERVABILITY_DEMO_APP_ENABLED=true` 时，才会
同步示例工作负载 Dashboard。生产平台安装器不会自动设置这两个 opt-in。
生产平台的非必选组件和高开销信号采集器由
[`infra/production/platform/feature-flags.example.env`](infra/production/platform/feature-flags.example.env)
控制；默认基线不读取宿主机 journald、Kubernetes audit 文件或逐条 Hubble flow，分别设置
`APPLY_HOST_JOURNALD=true`、`APPLY_KUBERNETES_AUDIT=true`、`APPLY_HUBBLE_EVENTS=true`
才会启用；Kubernetes Event 对象默认由 HA receiver 采集，也可用
`APPLY_KUBERNETES_EVENTS=false` 关闭。

WSL2 与 Windows：Kite、Prometheus、OpenObserve 和 Collector 使用 `kubectl port-forward`，业务入口使用 Cilium Gateway NodePort 的本地 socat 映射。各端口可在 WSL localhost 转发不可用时改用 `hostname -I` 返回的 WSL IP。OpenObserve UI 必须使用 <http://localhost:18081>，因为本地认证 Cookie 与 CORS 来源域明确绑定到 `localhost`；用 `127.0.0.1` 或 WSL IP 打开会导致查询 API 显示 `Failed to fetch`。不要将这些端口暴露到不可信网络。
Vue 默认使用当前业务 Gateway origin 作为 OTLP 接入地址，所以从 Windows 使用 WSL IP 时浏览器遥测仍然经过同一 Gateway 和 Collector；如需固定地址，可在启动前设置 `VITE_OTEL_INGESTION_URL=http://<WSL-IP>:8080`。浏览器使用 `VITE_OTEL_INGESTION_KEY`，该密钥只对 Collector 入口有效，不应复用后端 `OPENOBSERVE_API_KEY`。

示例数据库凭据：PostgreSQL Service `postgres.gofr-demo.svc.cluster.local:5432`，MySQL Service `mysql.gofr-demo.svc.cluster.local:3306`，Redis Service `redis.gofr-demo.svc.cluster.local:6379`；PostgreSQL/MySQL 数据库和用户均为 `demo`，密码为 `demo-password`。`orders` 使用 PostgreSQL 保存订单并调用 `catalog`，`catalog` 使用 MySQL 保存商品并用 Redis 缓存单项读取，因此一次订单请求会实际访问 PostgreSQL、MySQL 和 Redis。外部业务入口统一走 Gateway API：`/`、`/api/orders`、`/api/catalog`；数据库、Collector 和运维 UI 保持集群内或通过 port-forward 访问，不通过业务 Gateway 暴露。
Kite 的匿名模式和 `admin` / `kite-admin` 仅用于 localhost 演示；生产环境应关闭匿名模式、替换 JWT/加密密钥并通过 Secret 管理管理员凭据。

验证和清理：

```bash
make verify
make down
```

提交前建议运行 `make check`。它会检查 shell 语法、Git 空白错误、Go
测试/静态检查/构建和前端生产构建；CI 对同一组本地质量门禁执行验证。

`verify.sh` 检查 Gateway API CRD、GatewayClass、Gateway、HTTPRoute、Cilium agent、Cilium Envoy 数据面、MySQL/Redis/应用 Deployment、HPA/KEDA、Kite、OpenObserve、CRUD 请求和 GoFr 指标。`down.sh` 默认删除 k3d 集群；`MODE=host-k3s ./scripts/down.sh` 才会卸载宿主机 k3s。

## 浏览器遥测与会话回放

后端 GoFr 使用 OTLP/gRPC 发往集群内 Collector；浏览器使用 OTLP/HTTP 经 Gateway 进入同一个 Collector。Collector 负责入口认证、CORS、限流、脱敏、批处理和出口路由，当前默认出口是 OpenObserve v1.1.2，也可以替换为其他 OTLP 后端。默认：

```bash
export OPENOBSERVE_API_KEY=...
export OPENOBSERVE_OTLP_ENDPOINT=https://in-otel.openobserve.io
export OPENOBSERVE_API_VERSION=v2
```

本地模式使用上方表格中的 OpenObserve 账号登录即可查看 Traces、Logs、Metrics 和 Session Replay。不要提交 API 密钥；后端出口密钥由 Secret 注入。浏览器使用独立的 `VITE_OTEL_INGESTION_KEY`，只允许访问项目 Collector；生产环境应为它配置受限密钥，并单独管理后端 `OPENOBSERVE_API_KEY`。切换到 Cloud 时再设置 `OPENOBSERVE_MODE=cloud OPENOBSERVE_API_KEY=your-key`。

项目事件规范见 [`docs/observability-events.md`](docs/observability-events.md)。业务组件只使用 `telemetry.trackEvent(...)`，OpenObserve `addAction` 仅存在于适配层；事件名称、属性基数、脱敏、采样和保留策略都按项目规范维护。

前端显式开启 OpenObserve 会话回放、控制台采集、完整网络请求捕获和 W3C trace 传播；页面中的 `Mark demo action` 按钮会生成带时间戳的自定义动作，订单 CRUD 请求会进入同一个浏览器到后端的链路。演示页面提供明确的 Pause/Resume recording、Session ID 复制、错误反馈和删除确认，便于在 OpenObserve Sessions 中直接查看完整操作过程。

完整演示顺序：1) 打开应用入口，页面默认开始会话回放；2) 点击 `Mark demo action`，页面会显示已记录时间，再到 OpenObserve Sessions 查看当前会话；3) 在 Traces 中按 `k3s-gofr-web`、`k3s-gofr-orders` 或 `k3s-gofr-catalog` 查看浏览器 → Cilium Gateway → orders → catalog → PostgreSQL/MySQL/Redis 链路，并在 Cilium/Hubble 中查看 Pod 流量；4) 在 Prometheus 查询 `gofr:http_responses:rate5m`、`gofr:http_response_duration_seconds:p95`、`catalog_cache_operations_total` 或 `up{job="gofr-services"}`；5) 运行 `./scripts/load-test.sh`，观察 `kubectl -n gofr-demo get hpa,pods -w` 中 orders 扩容；6) 在 Kite 查看 Gateway、Deployment、Pod、HPA 和事件；7) 查看 Cilium：`kubectl -n kube-system get pods -l k8s-app=cilium`。`Pause recording` / `Resume recording` 只控制当前浏览器会话的录制器，不会删除已有回放。

OpenObserve 的 SQL 编辑器必须遵守 ClickHouse 子句顺序：`FROM` → `WHERE` → `ORDER BY` → `LIMIT`。例如下面的查询可以直接粘贴到 Traces：

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

`0 Results` 表示时间窗口内没有匹配 span；`Failed to fetch` 则通常表示查询请求失败。此前的示例把 `ORDER BY` 放在 `WHERE` 前，ClickHouse 会返回语法错误。`make verify` 会先产生一笔订单请求，再用正确的 SQL 验证 `POST /api/orders` 已写入 OpenObserve。

## 本地开发

```bash
cd services
go mod tidy
go run ./catalog
go run ./orders
cd ../frontend/web && pnpm install && pnpm dev
```

`services/go.mod`、`services/go.sum` 和 `services/go.work` 都属于后端目录：当前仓库只有一个 Go 模块，工作区文件放在模块旁边可以让 `go test ./...`、`go vet ./...` 和 `go build ./...` 的作用域清晰一致。根目录 `Makefile` 只负责进入 `services/` 调用这些命令；基础设施、前端和脚本不放进后端模块，避免把 Kubernetes YAML 或 Node 依赖混入 Go 模块的依赖图。

后端镜像构建上下文也保持在 `services/`：

```bash
docker build -f services/Dockerfile --build-arg SERVICE=catalog services
docker build -f services/Dockerfile --build-arg SERVICE=orders services
```

本地 `make up` 使用 `services/Dockerfile.runtime` 把宿主机编译出的二进制打包进运行时镜像；这样启动脚本不需要在 Docker build 阶段再次访问 Go 模块下载源。

GoFr 默认 HTTP 端口是 8000、指标端口是 2121；本示例部署环境使用默认端口。GoFr 自动提供 `/.well-known/health`、`/.well-known/alive` 和 `/metrics`。

Cilium Gateway 监听器使用 80；本地 k3d 通过 Cilium 分配的 NodePort 映射到 `8080:80`，云上则由 LB-IPAM/BGP 或云 LoadBalancer 提供 80/443。Web Deployment 内的 Nginx 只监听 8080、提供 Vue 静态文件，`/api` 完全由 Gateway API 转发到 orders。

### 设计说明

- GoFr 自带 HTTP 请求链路追踪、结构化日志、Prometheus 指标和健康探针；通过 `TRACE_EXPORTER=otlp` 发到 Collector。
- `orders` 用 W3C `traceparent` 传播头调用 `catalog`，一次浏览器请求会形成浏览器 → Gateway → orders → catalog 的完整链路。
- Cilium 提供集群 CNI、Gateway API、网络策略、Hubble 和 eBPF 数据路径；k3d 和生产模板都在集群创建阶段关闭 kube-proxy，并由 Cilium 接管 Service 数据面。
- `kubeProxyReplacement` 不是运行时热切换：如果现有主机集群还运行 kube-proxy，应按生产模板重建节点或集群后再启用，并验证 API server、NodePort/LoadBalancer 和 Cilium socket-LB。
- Cilium 是实现 Gateway API 的控制器。`GatewayClass` 的 `controllerName` 固定为 `io.cilium/gateway-controller`。

## 目录

- `infra/k3s`：namespace 与 k3s 运行边界
- `infra/network`：Cilium values、LB-IPAM 预览池、GatewayClass/Gateway/HTTPRoute
- `infra/apps`：本地示例的 GoFr orders/catalog、Vue web Deployment/Service，以及 HPA/PDB
- `infra/observability`：本地示例的 OpenObserve、Prometheus、OTel Collector 和 OTLP pipelines
- `infra/data`：本地示例的 PostgreSQL、MySQL 和 Redis，不属于生产平台依赖
- `infra/production`：生产 K3s 平台、存储后端、OpenObserve、OTel、网络和证书合约
- `services`：独立 Go module（`go.mod`、`go.sum`、`go.work`、`Dockerfile`）与 catalog/orders 源码
- `frontend/web`：Vue + OpenTelemetry/OpenObserve 适配层 + 会话回放
- `docs`：架构边界和本地运行手册
- `docs/observability-events.md`：业务事件、属性和厂商适配规范
- `.github/workflows`：不依赖集群的持续集成质量门禁

Kite 使用官方 `kite-org/kite` Helm OCI chart；`infra/dashboard/kite.yaml` 开启本地匿名演示、稳定密钥、SQLite PVC，并通过配置文件自动注册 `in-cluster` 为默认集群。没有 Helm 时，`infra/dashboard/kite-fallback.yaml` 提供等价的 Secret、PVC、Deployment 和 Service，不再使用官方最小 `deploy/install.yaml`，因此资源页不会因没有登录态或当前集群上下文而显示 `Failed to fetch`。Kite 和 Prometheus 都只通过 port-forward 暴露。

## 弹性演示

启动后运行 `./scripts/load-test.sh`（需要 `hey`）。另一个终端执行 `kubectl -n gofr-demo get hpa,pods -w`，可以看到 orders 从 2 副本扩展，Gateway 和 web/catalog 也能在多 Pod 间路由。HPA 依赖 k3s 自带 metrics-server；PDB 保证滚动维护时至少保留一个可用副本。
生产蓝图中的持久化后端是可选项：可以使用云厂商 CSI，也可以选择 Longhorn。选择
Longhorn 时使用 `infra/production/storage/longhorn-values.yaml` 和
`longhorn-storageclass.yaml` 创建 `fast-rwo`；本地 k3d 演示仍使用 K3s 自带的
`local-path`，不会安装 Longhorn。
