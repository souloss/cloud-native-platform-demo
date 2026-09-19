# 云原生平台演示架构

Cloud Native Platform Demo 是一个刻意保持小而完整、同时按生产形态组织的
平台参考项目。它把服务边界、流量策略、遥测管道、数据存储和运维流程放在同一个
本地 k3d 集群中，方便复现和验证。

## 分层模型

| 层级 | 职责 | 仓库位置 |
| --- | --- | --- |
| 边缘入口 | Gateway API 契约、Envoy 代理、路径路由 | `infra/network` |
| 运行时 | k3s、Cilium CNI、网络策略和 Hubble 流量可见性 | `infra/k3s`、`infra/network` |
| 业务工作负载 | GoFr `orders`、`catalog` API 以及 Vue Web 客户端 | `services`、`frontend/web`、`infra/apps` |
| 数据层 | PostgreSQL、MySQL 和 Redis 支撑服务 | `infra/data` |
| 可观测性 | OpenTelemetry Collector、Prometheus 和 HyperDX v2 | `infra/observability` |
| 运维层 | Kite 控制台、可重复的生命周期操作和验收检查 | `infra/dashboard`、`scripts`、`Makefile` |

边界是刻意设计的：应用代码不包含 Kubernetes 对象，基础设施不包含应用构建逻辑，
只有脚本负责组装本地运行环境。

## 请求与信号路径

```text
浏览器（Vue + 会话回放）
  -> Envoy Gateway / Gateway API
    -> web（静态界面）
    -> orders -> PostgreSQL
              -> catalog -> MySQL
                        -> Redis 缓存

浏览器 OTLP/HTTP -> Envoy Gateway -> OpenTelemetry Collector -> OTLP 后端
GoFr OTLP/gRPC -> OpenTelemetry Collector -> OTLP 后端
Pod 指标 -> Prometheus
Pod 网络流量 -> Cilium/Hubble
集群资源/事件 -> Kite
```

`orders` 调用 `catalog` 时会传播 W3C trace context，因此一笔订单请求可以作为端到端
链路追踪示例，而不是一组彼此割裂的健康检查。GoFr 还会生成结构化请求日志和
Prometheus 指标；应用处理器额外记录业务 span 以及缓存命中/未命中事件，因此同一请求
可以从三类信号进行排查。

## 生产形态设计

- Gateway API 是公开契约；Envoy 代理 Service 保持为 `ClusterIP`，本地只通过
  `kubectl port-forward` 暴露。
- 工作负载配置多副本、资源请求/限制、就绪和存活探针、PodDisruptionBudget 以及基于
  CPU 的 HPA。
- 无状态工作负载使用滚动更新和按主机名拓扑分布；探针区分启动、就绪和存活，避免
  依赖较慢的进程尚未准备好就接收流量。
- Prometheus 使用本地 TSDB PVC，并为主要 GoFr 请求速率和延迟信号配置 recording rule。
  规模虽然仍然很小，但运维人员可以查询稳定的项目指标，而不必依赖原始指标名。
- 应用密钥通过 Kubernetes Secret 注入。仓库中的值只用于本地教学环境。
- Cilium 替换 k3s 默认网络组件，但便携的 k3d 配置仍启用 kube-proxy。无 kube-proxy
  配置应当作为独立集群设计，而不是运行时开关。
- 浏览器不直接连接 HyperDX 或其他厂商后端，而是通过 Gateway 进入 Collector。Collector
  负责入口密钥校验、CORS、限流、脱敏和批处理，出口只使用部署方配置的 OTLP endpoint。
- 本地可观测性栈完全自包含。启动时设置 `HYPERDX_MODE=cloud` 并提供端点和
  API key，即可把 Collector 出口切换到 HyperDX Cloud；业务代码和浏览器入口无需改变。
- 业务事件名称和属性由 [`observability-events.md`](observability-events.md) 统一定义，
  前端通过项目 Telemetry API 发送，厂商 SDK 只位于适配层。

## 本地化取舍

集群使用 1 个 server、2 个 agent，状态存储使用单副本，PVC 使用 local-path，应用镜像
使用导入 k3d 的 `:dev` 标签。这些取舍让演示可以在工作站上稳定复现；生产部署应为每个
镜像固定 release 或 digest，使用托管数据服务或经过验证的存储类，将密钥外置，并定义
备份/恢复和 SLO 策略。
