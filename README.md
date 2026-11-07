# Cloud Native Platform Demo

一个可在 Linux 本机复现的云原生平台参考实现：用 k3d 运行 K3s，用 Cilium 提供
CNI、eBPF 服务数据面和 Hubble，用 Envoy Gateway 提供 Gateway API 入口，用 GoFr
展示微服务与数据访问，再用 OpenTelemetry 和 OpenObserve 串起日志、指标、链路和
浏览器会话回放。

仓库同时包含一套面向已有 Linux 主机的生产 K3s 部署蓝图。两种场景边界清晰：

- **本地演示**：`make demo-up` 创建隔离的 k3d 集群，部署完整示例应用和观测组件。
- **生产平台**：`make production-platform` 和 `make production-storage` 只处理已有
  K3s 集群的平台组件与存储后端，不会部署本地示例应用。

## 架构

```text
浏览器（Vue + Session Replay）
          │
          ▼
   Envoy Gateway API
          │
    ┌─────┴─────┐
    ▼           ▼
  web       orders ──────► catalog
                            │
                 PostgreSQL / MySQL / Redis

浏览器与 GoFr 服务 ── OTLP ──► OpenTelemetry Collector ──► OpenObserve
K3s 网络 ───────────────► Cilium CNI / Hubble
集群资源 ───────────────► Kite
```

一次订单请求会经过 Gateway、`orders` 和 `catalog`，并访问 PostgreSQL、MySQL 和
Redis。这样可以在同一个环境里观察入口路由、服务调用、数据库访问、缓存命中、
容器日志、Prometheus 格式指标和 OpenTelemetry 链路。

## 快速开始

需要 Linux、Docker、`curl`、`kubectl` 和 `make`。启动脚本会按需安装 k3d、Helm 和
`kubectl`，并从网络拉取镜像与 Helm chart；建议至少准备 4 CPU、8 GB 内存。

```bash
make demo-up
make demo-verify
```

启动完成后可访问：

| 组件 | 地址 | 说明 |
| --- | --- | --- |
| 业务入口 | <http://127.0.0.1:8080> | Vue 前端、Gateway API、订单和商品 API |
| Kite | <http://127.0.0.1:18080> | 本地演示账号：`admin` / `kite-admin` |
| OpenObserve | <http://localhost:18081> | 默认账号：`demo@cloud-native.local` / `CloudNative#2026` |

OpenObserve 必须使用 `localhost` 打开，以保证认证 Cookie 和 CORS 来源一致。以上
账号和密码只用于本机演示，生产环境必须改为 Secret 或外部密钥管理。

停止并删除本地演示集群：

```bash
make demo-down
```

`make up`、`make verify` 和 `make down` 是上述三个目标的兼容别名。默认集群名为
`gofr-demo`，端口转发和临时文件位于 `.runtime/`，不会清理其他 Docker 容器或主机服务。

## 常用命令

| 命令 | 用途 |
| --- | --- |
| `make demo-up` | 创建或更新 k3d 集群并部署本地示例 |
| `make demo-verify` | 检查 Gateway、工作负载、CRUD 和遥测链路 |
| `make status` | 查看节点、Pod、Gateway、HTTPRoute、HPA 和 PDB |
| `make network-status` | 查看 Cilium CNI、Envoy Gateway 和 Gateway 状态 |
| `make logs` | 查看 Cilium、orders 和 catalog 日志 |
| `make load-test` | 运行 HPA/负载均衡演示（需要 `hey`） |
| `make check` | 执行 Shell、Go 测试/静态检查、构建和前端构建 |
| `make observability-dashboards` | 将版本化 Dashboard 同步到 OpenObserve |

需要自定义端口或运行目录时，例如：

```bash
RUNTIME_DIR=.runtime-preview \
APP_PORT=28080 KITE_PORT=28082 OPENOBSERVE_PORT=28083 \
COLLECTOR_HTTP_PORT=24318 make demo-up
```

如需复用宿主机已有的 K3s，可显式设置 `MODE=host-k3s`。该模式会操作宿主机的 K3s
服务，清理前请确认目标集群；默认的 `MODE=k3d` 更适合本地演示。

## 生产部署蓝图

生产部署要求先完成节点、网络、TLS、密钥和持久化准备。推荐顺序如下：

1. 按 [`docs/production-blueprint.md`](docs/production-blueprint.md) 准备 3 个 K3s
   server、worker、私有 API LB/VIP 和版本化配置。
2. 选择一个存储后端：`longhorn` 或云厂商 CSI，创建 `fast-rwo` StorageClass。
3. 在已有集群上执行 `make production-storage`，再执行 `make production-platform`。
4. 按需应用生产 Gateway、证书、OpenObserve、OTel Collector 和业务方自己的工作负载。

生产安装器默认只安装平台能力，不会自动安装本地 PostgreSQL、MySQL、Redis、Nginx、
Kite 或 GoFr 示例。生产凭据必须通过外部 Secret、SOPS 或云密钥管理服务
注入；不要把真实 token、密码或 API key 提交到仓库。

## 目录与文档

```text
services/                 GoFr catalog/orders 微服务
frontend/web/             Vue 前端与浏览器 OpenTelemetry 适配层
infra/                    本地 k3d 清单与生产平台/观测/存储契约
scripts/                  本地生命周期、验收、负载和生产安装脚本
docs/                     架构、运行手册、观测事件和生产蓝图
```

- [`docs/architecture.md`](docs/architecture.md)：组件边界、请求路径和观测信号。
- [`docs/runbook.md`](docs/runbook.md)：本地启动、验收、端口、排障和清理。
- [`docs/observability-events.md`](docs/observability-events.md)：业务事件与脱敏规范。
- [`docs/production-blueprint.md`](docs/production-blueprint.md)：生产节点、存储、TLS、
  OpenObserve 和升级策略。
- [`infra/production/README.md`](infra/production/README.md)：生产清单的目录边界和开关。

## 版本与边界

本地脚本默认固定 K3s、Cilium、Gateway API、Envoy Gateway、KEDA、OpenTelemetry
Operator 和 OpenObserve 版本，均可通过脚本中的环境变量覆盖。具体版本和镜像清单以
[`scripts/up.sh`](scripts/up.sh) 及 [`scripts/production/platform.sh`](scripts/production/platform.sh)
为准。

项目不部署独立的 Prometheus Server。GoFr、Cilium、Hubble、KEDA 和 Envoy Gateway
仍可暴露 Prometheus 格式指标，由 OTel Collector 采集并写入 OpenObserve；K3s 内置
`metrics-server` 负责 HPA 的 CPU/内存指标，KEDA 直接查询 OpenObserve 的 PromQL API。

本项目是平台演示和生产部署蓝图，不是开箱即用的生产集群。生产环境仍需按实际云
网络、故障域、数据保留、容量、备份、密钥和恢复目标完成评审与压测。
