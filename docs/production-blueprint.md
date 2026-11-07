# K3s + Cilium + OpenObserve 生产蓝图

## 2026-11 版本锁定

本蓝图锁定在 2026-11-07 发布源可见的最新稳定版本；部署流水线应同时记录解析后的
镜像 digest。预发布版本、`latest`、`main` 和 RC 标签不纳入生产锁定。

| 组件 | 锁定版本 |
| --- | --- |
| K3s | `v1.37.2+k3s1` |
| Helm | `v4.3.1` |
| Gateway API | `v1.7.0` |
| Cilium | `1.20.4` |
| cert-manager | `v1.21.3` |
| Kured | Chart `6.1.0` / App `1.23.0` |
| System Upgrade Controller | Chart `110.0.0` / App `v0.20.1` |
| KEDA | `2.21.0` |
| OpenTelemetry Operator | Chart `0.129.0` / App `0.162.0` |
| OTel Collector | `0.162.0` |
| OpenObserve | Chart `1.1.4` / App `v1.1.2` |
| Prometheus（本地示例可选） | `v3.16.0` |
| PostgreSQL（本地示例可选） | `18.6-alpine3.24` |
| MySQL LTS（本地示例可选） | `8.4.13` |
| Redis（本地示例可选） | `8.8.4-alpine3.23` |
| Optional CSI | Longhorn Chart/App `1.13.0`, or a cloud-provider CSI driver |

K3s 发行版的内置镜像（CoreDNS、metrics-server、klipper-helm 等）也在
`scripts/up.sh` 中显式锁定；升级 K3s 时必须重新核对这组镜像和官方 air-gap 清单。

## 三条明确的运行入口

仓库把本地演示、生产平台和持久化后端分成三个入口：

```bash
# 本地 k3d：平台 + OpenObserve + 示例应用和示例数据依赖
make demo-up
make demo-verify
make demo-down

# 已经完成 K3s 节点安装、网络和密钥准备后，只安装生产平台
KUBECONFIG=/path/to/production.kubeconfig \
CILIUM_K8S_SERVICE_HOST=10.0.0.10 \
STORAGE_BACKEND=cloud-csi \
make production-platform

# 选择 Longhorn 作为 CSI；云厂商 CSI 则用 STORAGE_BACKEND=cloud-csi
KUBECONFIG=/path/to/production.kubeconfig \
STORAGE_BACKEND=longhorn \
make production-storage
```

`make up`、`make verify` 和 `make down` 只是旧入口的本地演示兼容别名。
生产入口不会部署 PostgreSQL、MySQL、Redis、Nginx、Kite、示例应用或本地
Prometheus，也不会自动生成生产 Secret。K3s 节点仍需按 SSH 节点模板逐台加入，
因为 API LB/VIP、云安全组、令牌和节点磁盘属于环境边界，不能由通用目录安全猜测。
`production-platform` 安装的是集群级能力；KEDA 默认安装但不创建任何应用的
`ScaledObject`。不需要事件扩缩容时可设 `INSTALL_KEDA=false`。GoFr 示例的
OpenObserve 查询、认证 Secret 和 `ScaledObject` 只通过单独的
`make production-example-autoscaling` 入口创建。

平台安装器的非必选组件开关如下；开关值只影响本次安装/应用，卸载行为需要显式执行：

| 开关 | 默认 | 作用 |
| --- | --- | --- |
| `INSTALL_CERT_MANAGER` | `true` | TLS/Issuer 控制器；没有集群内证书需求时设为 `false` |
| `INSTALL_KURED` | `true` | 节点自动 reboot/drain；需由维护窗口和云节点策略支持 |
| `INSTALL_SYSTEM_UPGRADE_CONTROLLER` | `true` | K3s 分阶段升级；不采用 SUC 时设为 `false` |
| `INSTALL_KEDA` | `true` | 事件驱动扩缩容控制器；不使用 KEDA 时设为 `false` |
| `INSTALL_OPENOBSERVE` | `true` | 安装集群内 OpenObserve；使用托管后端时设为 `false` |
| `INSTALL_STORAGE` | `true` | 管理/校验 Longhorn 或云 CSI；关闭时 OpenObserve 仍要求已有 `fast-rwo` |
| `INSTALL_OTEL_OPERATOR` | `true` | 管理 OTel Collector CR；`APPLY_COLLECTOR=true` 时必须开启 |
| `APPLY_COLLECTOR` | `true` | 应用 OTel Gateway + Agent 基线 |
| `ENABLE_HUBBLE` | `true` | Cilium Hubble Relay/metrics；不采集网络观测时设为 `false` |
| `APPLY_HOST_JOURNALD` | `false` | 采集 K3s/containerd 等 systemd journal |
| `APPLY_KUBERNETES_AUDIT` | `false` | 采集 K3s API audit 文件；需先启用 K3s audit 参数 |
| `APPLY_KUBERNETES_EVENTS` | `true`（Collector 开启时） | 通过 Leader Election 采集 Kubernetes Event 对象 |
| `APPLY_HUBBLE_EVENTS` | `false` | 采集 Cilium 逐条 flow JSON；同时启用 Cilium static exporter |
| `ENABLE_HUBBLE_EVENTS` | `false`（由 `APPLY_HUBBLE_EVENTS` 自动继承） | 控制 Cilium static Hubble exporter |
| `REMOVE_OPTIONAL_COLLECTORS` | `false` | 删除未在本次开关中启用的三个可选 Collector |
| `APPLY_EDGE_RESOURCES` | `false` | 应用生产 Gateway、Certificate 和 OpenObserve Route |
| `APPLY_DASHBOARDS` | `false` | 同步版本化 OpenObserve Dashboard |

为了尽可能完整地采集生产信号，可在确认节点权限和存储后使用：

```bash
INSTALL_CERT_MANAGER=true \
INSTALL_KURED=true \
INSTALL_SYSTEM_UPGRADE_CONTROLLER=true \
INSTALL_KEDA=true \
INSTALL_OPENOBSERVE=true \
INSTALL_OTEL_OPERATOR=true \
APPLY_COLLECTOR=true \
APPLY_HOST_JOURNALD=true \
APPLY_KUBERNETES_AUDIT=true \
APPLY_KUBERNETES_EVENTS=true \
APPLY_HUBBLE_EVENTS=true \
ENABLE_HUBBLE=true \
APPLY_EDGE_RESOURCES=true \
APPLY_ISSUERS=true \
make production-platform
```

`APPLY_KUBERNETES_AUDIT=true` 之前必须把
`infra/production/k3s/audit-policy.yaml` 复制到每台 server 的
`/etc/rancher/k3s/audit-policy.yaml`，并在 server 配置中启用同名的
`kube-apiserver-arg`。也可以在首次 SSH 安装 server 时设置
`ENABLE_KUBERNETES_AUDIT=true`，安装器会校验该参数并安装 policy 文件。现有节点不能
通过这个安装器热添加 audit 参数，应按 K3s 维护窗口修改配置并重启 API server。
`APPLY_HUBBLE_EVENTS=true` 会把 Hubble flow 写入每个节点的
`/var/run/cilium/hubble/events.log` 并由独立的 DaemonSet 读取，开销和数据量明显高于
Hubble metrics；没有网络审计需求时保持关闭。

k3s 节点可以使用 `scripts/production/install-node.sh` 简化逐台 SSH 安装。先通过
密钥管理器把相应的 `server-init.yaml`、`server-join.yaml` 或 `agent.yaml` 渲染到
节点上的 root-only 临时文件，再执行：

```bash
K3S_CONFIG_FILE=/run/secrets/k3s-config \
  scripts/production/install-node.sh server-init
# 其他控制面节点：scripts/production/install-node.sh server-join
# worker 节点：scripts/production/install-node.sh agent
```

该脚本不会自动升级已有节点；已有节点的版本变化交给 System Upgrade Controller，
避免在生产环境中误触发并行升级。

`scripts/production/platform.sh` 是已有生产 K3s 集群上的幂等平台安装器；它会拒绝
k3d kubeconfig，检查控制面/worker 数量，安装固定版本的平台 Helm release，并在
OpenObserve、OTel 和边缘资源安装前检查外部 Secret。`scripts/production/storage.sh`
只允许 `longhorn` 或 `cloud-csi` 二选一。

这份蓝图针对“只有 SSH、不能替换云虚拟机操作系统”的约束。它把 K3s
安装在现有 Linux 上，把集群配置、控制器和应用交给 Git 管理。仓库原有的
k3d 演示仍然保留在 `make up`；`infra/production` 是云上部署的生产基线。

## 结论和边界

现有方案具备一个正确的方向：K3s、Cilium、Gateway API、metrics-server、KEDA
和 OpenTelemetry 能组成轻量的 Kubernetes 平台。但它还不能直接称为生产集群：

| 现状 | 生产要求 |
| --- | --- |
| k3d 的 1 个 server、2 个 agent | 3 个跨故障域的 K3s server，至少 2 个 worker |
| Cilium 保留 kube-proxy，VXLAN 隧道 | 新集群启用 kube-proxy replacement；路由模式按云网络验证 |
| 单独的 Gateway controller 与 Cilium 并存 | 生产只选择 Cilium Gateway API controller，避免多个 controller 争抢 GatewayClass |
| 单个 OTel Collector Deployment | OTel Operator 管理 DaemonSet Agent + 2 副本 Gateway |
| 本地 PVC、单副本 Prometheus/OpenObserve | OpenObserve 分布式组件、对象存储、PostgreSQL 元数据和 NATS |
| 手工 reboot / 手工升级 | Kured 单节点 drain + System Upgrade Controller 分阶段升级 |
| 明文演示 Secret | External Secrets、SOPS 或云密钥管理服务 |
| HTTP/port-forward 入口 | cert-manager 签发 TLS，云 LB/BGP/LB-IPAM 提供稳定入口 |

OpenObserve 统一承载本地演示和生产观测。生产数据面不是一个带 PVC 的单 Pod：日志、指标和
链路数据应写入 S3 兼容对象存储，集群元数据写入 PostgreSQL，队列由 3 节点 NATS
JetStream 提供，查询和写入组件分别扩容。仓库的 OpenObserve values 已按这个边界
配置，密钥和实际地址仍必须由部署环境提供。
Collector 出口地址由 `observability/openobserve-otel` Secret 的 `endpoint` 字段提供，
默认指向集群内 OpenObserve router；使用托管 OpenObserve 时只替换这个 Secret 值和
`authorization`，并设置 `INSTALL_OPENOBSERVE=false`，无需改 Collector 清单。

OpenObserve 还提供 RUM 和 Session Replay。浏览器 SDK 的 `applicationId`、
`clientToken` 和采样率需要在 OpenObserve 中创建应用后注入前端；它们不能用
Collector 的后端 Basic Auth 代替。生产环境应给 RUM 单独的组织和客户端 token，
并在 SDK 中启用输入遮罩、资源/错误采样和保留策略。

仓库中的 PostgreSQL、MySQL、Redis 和 Nginx 只属于本地业务示例：它们用于让
`orders`、`catalog` 和 Vue 前端可以自包含运行，不是 K3s 平台的生产前置条件。
生产环境应由业务团队选择托管数据库、CloudNativePG、缓存服务或静态站点/CDN，
并从生产安装顺序中删除不需要的示例清单。Prometheus 同样是可选的兼容组件；
OpenObserve 承载生产指标、日志和链路时，可以只保留 metrics-server 用于 HPA，
不部署仓库中的本地 Prometheus Deployment。

仓库前端已经提供可选的 OpenObserve 适配器。生产构建设置
`VITE_OBSERVABILITY_BACKEND=openobserve`、`VITE_OO_RUM_APPLICATION_ID`、
`VITE_OO_RUM_CLIENT_TOKEN` 和 `VITE_OO_RUM_SITE` 即可启用；默认本地构建仍使用
OpenObserve 演示后端。适配器的配置形态如下（值通过构建时 Secret 注入）：

```js
import { openobserveRum } from '@openobserve/browser-rum'

openobserveRum.init({
  applicationId: import.meta.env.VITE_OO_RUM_APPLICATION_ID,
  clientToken: import.meta.env.VITE_OO_RUM_CLIENT_TOKEN,
  site: import.meta.env.VITE_OO_RUM_SITE,
  service: 'web',
  env: 'production',
  version: import.meta.env.VITE_APP_VERSION,
  sessionSampleRate: 20,
  sessionReplaySampleRate: 5,
  trackResources: true,
  trackLongTasks: true,
  trackUserInteractions: true,
  defaultPrivacyLevel: 'mask-user-input',
  startSessionReplayRecordingManually: true,
})
```

`clientToken` 只能写入浏览器 bundle，不能授予管理 API 权限；Session Replay 的
默认隐私级别、输入遮罩和用户同意流程必须在业务上线前完成评审。业务自定义事件
继续通过项目的 `telemetry` 门面发送，避免组件直接依赖 SDK。

## 节点和故障域

- 3 台 server 分布在至少 2 个可用区，使用嵌入式 etcd；API Server 前放一个私网
  LB/VIP，6443 只允许管理网段访问。
- worker 至少 2 台，应用和观测组件设置 `topologySpreadConstraints`，不要让副本
  全部落在同一台虚拟机。
- server 使用本地 SSD 或云盘，etcd 需要稳定低延迟 I/O；不要把 etcd 放在临时盘。
- OpenObserve 的 NATS、缓存和 PostgreSQL 使用支持快照/替换节点的 `fast-rwo` CSI
  StorageClass。蓝图支持两种后端：可选的 Longhorn `1.13.0`，或云厂商 CSI；两者
  只能选择一个，不能同时管理同一个 `fast-rwo`。
  对象存储使用云 S3、兼容 S3 的托管服务或经过故障演练的 MinIO 集群。
- 一个可用的起始容量是每台 server 4 vCPU/8 GiB、每台 worker 4 vCPU/8 GiB。
  OpenObserve 另预留至少 4 vCPU/16 GiB 的资源池；实际大小按每天摄入量、查询并发
  和保留时间压测决定，不能用演示环境的 8 GiB 结论直接上线。

## 安装顺序

生产安装需要一次性的 SSH 主机准备动作，但集群内对象均由 Helm、CRD 和 GitOps
清单管理。先为每台主机准备时间同步、内核/eBPF 依赖、磁盘、云安全组和容器运行时，
再按下面顺序安装：

1. 在第一台 server 写入 `infra/production/k3s/server-init.yaml`，安装固定版本的
   K3s；第二、第三台使用 `server-join.yaml` 加入同一个 API LB。worker 使用
   `agent.yaml`。真实 token 只放在 root-owned 文件或密钥管理服务中。
2. 安装 Gateway API CRD 和 Cilium。Cilium 必须使用与创建集群时一致的
   `kubeProxyReplacement`、Pod CIDR、API 地址和路由模式。KPR 不是对现有集群的
   热开关，出现不兼容时应重建节点/集群，而不是在线改 values。
3. 选择并安装持久化后端。选择 Longhorn 时，先应用
  `infra/production/storage/namespace.yaml`，再使用
   `infra/production/storage/longhorn-values.yaml` 安装 Longhorn `1.13.0`，最后应用
   `longhorn-storageclass.yaml` 创建 `fast-rwo`。选择云厂商 CSI 时跳过 Longhorn，
   但必须由云 CSI 提供同名且支持扩容、快照、替换节点和 `WaitForFirstConsumer` 的
   `fast-rwo` StorageClass。确认 `kubectl get storageclass fast-rwo` 成功后继续。
4. 安装 cert-manager、Kured、System Upgrade Controller、云 LB 集成（或 Cilium
   LB-IPAM/BGP）和 KEDA。应用工作负载
   只保留一个扩缩容 owner：CPU/内存用原生 HPA，队列/lag/请求速率用 KEDA；同一个
   Deployment 不要同时绑定独立 HPA 和 KEDA ScaledObject。
5. 安装 CloudNativePG Operator 并创建 PostgreSQL 集群，或使用托管 PostgreSQL。
   再应用 `infra/production/observability/namespace.yaml` 和外部 Secret，最后用 OpenObserve chart 安装
   `infra/production/observability/openobserve-values.yaml`。
6. 安装 OpenTelemetry Operator，创建 `infra/production/observability/collector.yaml`。
   应用 OTLP gRPC/HTTP 只指向 Gateway Service；Agent 读取每个节点的容器日志并把
   日志发给 Gateway。Gateway 负责脱敏、批处理、重试和导出到 OpenObserve。
7. 应用生产版 Gateway、NetworkPolicy、ResourceQuota、PodDisruptionBudget、应用
   Deployment 和 KEDA 对象；应用 `infra/production/network/gateway.yaml`、
   `certificate.yaml` 和 `openobserve-route.yaml`。业务 Gateway 与 OpenObserve
   UI/摄入入口使用不同的 hostname，避免 `/api` 路由互相覆盖。

每台主机只需要一次 SSH 初始化。把对应模板渲染到
`/etc/rancher/k3s/config.yaml`（权限 `0600`），然后运行官方安装器；不要把下面的
token 写进 Git 或 shell 历史：

```bash
# 第一个 server
install -o root -g root -m 0600 server-init.yaml /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.2+k3s1 sh -s - server

# 第二、第三个 server：server-join.yaml 中的 server 和 token 由密钥管理器渲染
install -o root -g root -m 0600 server-join.yaml /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.2+k3s1 sh -s - server

# worker：agent.yaml 中的 server 和 token 由密钥管理器渲染
install -o root -g root -m 0600 agent.yaml /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.2+k3s1 sh -s - agent
```

安装前在云安全组中只开放节点间所需的 VXLAN/WireGuard 或原生路由流量、6443 管理
入口和 Gateway 的 80/443；具体端口按所选 Cilium 路由模式和云厂商网络文档核对。
K3s token 建议由 `k3s token create --ttl` 生成并在加入后轮换。
在受控环境中应先下载并校验 K3s 安装脚本/二进制的官方 checksum，再执行安装器，
并把 `K3S_VERSION`、Helm chart 版本和镜像 digest 作为发布清单的一部分。

### 固定版本的安装命令

下面的命令只表达版本和依赖关系；实际执行应由 GitOps pipeline 或受控的 SSH 发布
窗口完成：

```bash
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system --create-namespace \
  -f infra/production/network/cilium-values.yaml
# STORAGE_BACKEND=longhorn 时执行；云厂商 CSI 选择则跳过以下三步。
kubectl apply -f infra/production/storage/namespace.yaml
helm repo add longhorn https://charts.longhorn.io
helm repo update longhorn
helm upgrade --install longhorn longhorn/longhorn --version 1.13.0 \
  -n longhorn-system --create-namespace \
  -f infra/production/storage/longhorn-values.yaml
kubectl apply -f infra/production/storage/longhorn-storageclass.yaml
helm repo add openobserve https://charts.openobserve.ai
helm repo update
helm upgrade --install openobserve openobserve/openobserve \
  --version 1.1.4 -n openobserve --create-namespace \
  -f infra/production/observability/openobserve-values.yaml
helm repo add kedacore https://kedacore.github.io/charts
helm upgrade --install keda kedacore/keda --version 2.21.0 \
  -n keda --create-namespace
helm repo add jetstack https://charts.jetstack.io
helm repo add kured https://kubereboot.github.io/charts
helm repo add rancher https://charts.rancher.io
helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.3 \
  -n cert-manager --create-namespace -f infra/production/platform/cert-manager-values.yaml
helm upgrade --install kured kured/kured --version 6.1.0 \
  -n kured --create-namespace -f infra/production/platform/kured-values.yaml
helm upgrade --install system-upgrade-controller rancher/system-upgrade-controller --version 110.0.0 \
  -n system-upgrade --create-namespace -f infra/production/platform/system-upgrade-controller-values.yaml
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator --version 0.129.0 \
  -n opentelemetry-operator-system --create-namespace -f infra/production/platform/otel-operator-values.yaml
```

只有部署 GoFr 示例应用并希望按 OpenObserve 请求速率扩缩时，才由密钥管理器创建
`gofr-demo/openobserve-keda`，再运行 `make production-example-autoscaling`。该入口会
确认 KEDA CRD、`orders` Deployment 和凭据都存在，之后才创建示例 `ScaledObject`。
其他应用应在自己的发布目录维护 KEDA `ScaledObject`，平台安装器不会替应用团队创建它。

OpenObserve chart 的 `postgres.enabled` 在本蓝图中关闭。必须在安装前把
`ZO_META_POSTGRES_DSN` 写入外部 Secret，并验证 PostgreSQL 的 TLS、备份、连接池和
故障切换；如果使用 CNPG，先安装与 chart 兼容的 CNPG 版本，再把 DSN 指向 CNPG
读写 Service。不要把 `postgres.password`、S3 key 或 root 密码写进 values 文件。

## 遥测管道

```text
应用 OTLP -> OTel Gateway (2 replicas) -> OpenObserve router -> ingester -> S3
节点日志 -> OTel Agent (DaemonSet) -> OTel Gateway
Cilium/Hubble metrics -----------------> OTel Gateway -> OpenObserve metrics
Hubble flow detail -> Hubble Relay（按需部署 UI，专用网络视图）
浏览器 RUM/Replay -> OpenObserve RUM hostname（独立 client token）
```

Gateway 的 OTLP HTTP exporter 使用
`http://openobserve-router.openobserve.svc.cluster.local:5080/api/default`，SDK 会在
其后追加 `/v1/traces`、`/v1/metrics` 或 `/v1/logs`。`Authorization` 是单独 Secret 中
保存的 Basic Auth；它只存在于 Gateway Pod，不能编译进浏览器。

OpenObserve 的服务图由 trace 数据在后端计算，不需要在 Collector 再添加
`servicegraph` connector。Hubble 的逐流事件仍然适合在 Hubble Relay/UI 中排查；
只把 Hubble/Cilium 的有限指标送入 OpenObserve，避免把高基数 flow 当作普通业务日志
无限摄入。Collector 必须设置 `memory_limiter`、`batch`、重试和限流，并明确删除
Authorization、Cookie、邮箱和请求正文等敏感属性。

## Gateway controller 的选择

仓库删除了 Envoy Gateway 的 Helm values 和资源，是因为生产集群只允许一个 Gateway API
controller。当前 controller 是 Cilium，数据面仍然是 Cilium 管理的 Envoy，路径为：

```text
Gateway / HTTPRoute -> Cilium Gateway controller -> Cilium Envoy -> eBPF/KPR/Hubble
```

因此删除的是第二套 controller，不是删除 Envoy 数据面，也不是否认 Envoy Gateway 的能力。
Envoy Gateway 在独立的 controller、策略 API、扩展过滤器或多团队网关隔离成为硬性需求时仍然
是合理选项；届时应关闭 Cilium Gateway API controller，保留 Envoy Gateway 作为唯一
`GatewayClass` owner，并重新验收 CNI、Service、NetworkPolicy 和 Hubble。两者不能在同一
集群同时管理相同的 GatewayClass/HTTPRoute。

metrics-server 只服务 Kubernetes HPA 的 CPU/内存指标，不是生产观测后端。OpenObserve
承载业务指标、日志、链路和 RUM；HPA/KEDA 的扩缩容信号仍应单独验证其时效性、冷却期
和最小副本数。

OpenObserve 提供 PromQL 兼容查询 API，所以 KEDA 可以直接查询 OpenObserve；这不等于它
完全复制了 Prometheus Server 的所有运行时语义。生产基线可以删除 Prometheus Server，
但必须保留 `metrics-server`（HPA 的 resource metrics API）和 OTel Collector（指标采集、
批处理、重试、导出）。只有在依赖 Prometheus 原生告警/recording rule、Prometheus TSDB
隔离保留或现有 Prometheus 生态时，才额外部署 Prometheus Server。它是兼容选项，不是
OpenObserve 的前置依赖。

## OpenObserve Dashboard 基线

Dashboard 以 JSON 版本化保存在
`infra/observability/dashboards/`，包含三个视图：

- `K3s Cluster Overview`：节点数、采集目标健康、每节点 CPU/内存/文件系统利用率、负载、网络 I/O、Hubble flow/drop、namespace 日志量和 trace 服务分布。
- `K3s Workloads & Autoscaling`：HTTP 响应计数与状态、响应时间总量、Go runtime、进程内存、SQL 连接、KEDA metrics endpoint 健康和 KEDA metrics 请求。
- `K3s Observability Pipeline`：日志/链路摄入量、OTel 接收和导出计数器、导出队列、失败点数、日志严重级别和 trace 状态。

Dashboard 同步脚本有两个 profile。生产默认是 `core`，只创建集群概览和观测管道；
`demo` 才会额外创建依赖 GoFr 指标（`app_http_response_count` 等）的示例工作负载
Dashboard；该 profile 还要求显式设置 `OBSERVABILITY_DEMO_APP_ENABLED=true`，并且必须
发现 GoFr 指标流。脚本还会读取当前 OpenObserve 的 metrics/logs/traces stream inventory，
自动删除没有数据源的可选面板。因此没有部署示例应用、KEDA 或 Hubble 时，不会因这些
组件缺失而生成对应的工作负载配置或空面板。启用默认清理时，它也会删除当前 profile
不包含的仓库管理 Dashboard，以及因所有数据源都缺失而无法更新的旧 Dashboard；其他
团队的 Dashboard 不在清理范围内。示例 profile 下只有发现 `app_http_response_count`
才会建立工作负载 Dashboard，否则同名旧面板也会被清掉。

节点面板使用 OTel Agent 的 `hostmetrics` receiver；它通过只读 `/hostfs` 采集 CPU、内存、
磁盘、文件系统、负载、网络和 paging，并由 `k8sattributes` 标记 `k8s_node_name`。生产
清单和本地预览清单都已接入这一 receiver，因此不需要额外维护 node-exporter。Collector
自身的 receiver/exporter 指标也由 Gateway 的 Prometheus receiver 转换成 OTel metrics，
再写入 OpenObserve；这里的 Prometheus receiver 是采集协议适配器，不是 Prometheus Server。

### 信号覆盖边界

| 信号 | 当前基线 | 需要业务/环境单独接入的部分 |
| --- | --- | --- |
| 指标 | 节点 hostmetrics、kubelet 的 Pod/容器/卷指标、Kubernetes 对象状态、OTel Collector 自身指标；Hubble/KEDA 指标通过 Service discovery 采集 | 应用通过 OTLP 上报，或由应用团队添加 scrape 配置；禁用的组件没有 scrape target |
| 日志 | DaemonSet Agent 读取 `/var/log/pods` 的容器 stdout/stderr；`APPLY_KUBERNETES_EVENTS=true` 时以 HA receiver 采集 Kubernetes Event 对象 | 宿主机 journald、K3s systemd 服务日志和 Kubernetes audit log 由独立开关接入；journald 路径和 audit policy 需按发行版/安全要求单独配置 |
| 链路 | OTLP traces 经 Gateway 脱敏、批处理后写入 OpenObserve；浏览器入口有独立 token | 应用需要埋点并发送 OTLP；平台不会自动生成应用链路 |
| 网络 | Hubble counters/flows/drop 等 Prometheus metrics | 逐条 Hubble flow event 没有作为日志导出；需要事件级网络审计时应单独启用 Hubble Relay/export pipeline |

因此这是一套覆盖 Kubernetes 资源、Event 对象与应用 OTLP 的生产起始基线，不代表已经接入宿主机
审计日志、所有应用指标或 SLO 告警。上线前应按实际合规、告警路由和保留策略补齐这些
输入，并用目标环境验证丢包、节点替换和后端不可用时的队列行为。

用外部 Secret 注入 OpenObserve 地址和账号后，在集群外部执行：

```bash
OPENOBSERVE_URL=https://observe.example.com \
OPENOBSERVE_EMAIL="$OO_ADMIN_EMAIL" \
OPENOBSERVE_PASSWORD="$OO_ADMIN_PASSWORD" \
make observability-dashboards
```

本地示例由 `scripts/up.sh` 显式设置 demo profile 和示例开关；生产只有确实部署了
示例应用后，才设置 `OBSERVABILITY_DASHBOARDS_PROFILE=demo` 与
`OBSERVABILITY_DEMO_APP_ENABLED=true`。生产 Collector 不含 GoFr 静态抓取目标，
平台组件的 scrape 使用 Kubernetes Service discovery；没有 Hubble、KEDA 或 Collector
monitoring Service 时不会配置固定地址或创建失败 target。应用指标由应用自行通过 OTLP
发送，或由应用团队单独维护 scrape 配置。`INSTALL_KEDA=false` 可以跳过 KEDA 控制器。
`INSTALL_*` 与 `APPLY_*` 是本次运行的安装门，不会自动卸载之前装好的 Helm release 或
已应用的 Collector；移除集群级组件需按 Helm release/CRD 的所有权单独执行卸载。Dashboard
同步脚本的默认 prune 则只删除本仓库管理的三个固定标题。

生产平台安装器也支持在同一个受控发布窗口应用 Dashboard：
`APPLY_DASHBOARDS=true`，并同时提供上述三个 `OPENOBSERVE_*` 环境变量。脚本按标题
幂等创建、更新或清理 profile 中的 Dashboard；密码和 token 不写入 JSON。每个查询已经在本地预览集群以
当前 stream schema 执行过，新增组件或改名后应重新运行查询验收。

core profile 默认清理仓库管理的旧版示例工作负载 Dashboard；若同一 OpenObserve 组织
还由其他团队维护同名资源，可设置 `OBSERVABILITY_DASHBOARDS_PRUNE=false`，然后手工
处理旧资源。

## 安全和运维门槛

- 为 `gateway-system`、`openobserve` 和业务 namespace 开启 Pod Security
  `restricted`。`observability` 因节点日志 Agent 的只读 `/var/log/pods` hostPath
  使用 `baseline`，并应对 Operator 生成的 Agent/Gateway Pod 做单独的安全上下文审查。
  所有镜像使用 digest、签名校验和 SBOM。
- Cilium 默认拒绝跨 namespace 流量，只放行 DNS、Gateway 到业务、Collector 到
  OpenObserve，以及必要的健康检查。不要把 OpenObserve 5080/5081 或 Kubernetes
  6443 直接暴露到公网。
- OpenObserve UI、摄入和 RUM 使用 TLS；UI 使用 SSO/OIDC 或至少独立的强 root 密码，
  RUM client token 与后端 Basic Auth 分离。前端只得到 RUM client token。
- 对象存储开启版本控制/生命周期，PostgreSQL 做 PITR，NATS 做持久卷快照；每季度
  在隔离环境执行一次恢复演练，验证从 S3、PostgreSQL、NATS 和 K3s 清单恢复的顺序。
- 记录每个组件的摄入量、丢弃量、队列长度、查询延迟、磁盘水位和证书过期时间，并
  为这些指标设告警。先定义日志/链路/指标保留期和采样预算，再设置 OpenObserve 的
  stream retention，避免观测系统自身吞噬业务资源。
- 发布前验证：3 台 server 失去任意 1 台仍能调度；任意 1 个 OTel Gateway 失效时
  Agent 能重试；对象存储短暂不可用时 Collector 有界排队；OpenObserve 任一 router
  或 querier 副本重启不影响摄入和查询；KEDA 不会在队列抖动时频繁缩放。

## 与仓库清单的对应关系

- K3s 配置模板：`infra/production/k3s/`
- Cilium KPR、Gateway API、Hubble 和 WireGuard：`infra/production/network/`
- 可选 CSI 存储后端和 `fast-rwo` StorageClass：`infra/production/storage/`
- OpenObserve 分布式 values 和外部 Secret 模板：`infra/production/observability/openobserve-*`
- OTel Operator Agent/Gateway：`infra/production/observability/collector.yaml`
- 可选完整信号 Collector：`collector-kubernetes-events.yaml`、`collector-journald.yaml`、
  `collector-kubernetes-audit.yaml`、`collector-hubble-events.yaml`
- Collector 到 OpenObserve 的出口凭据模板：`infra/production/observability/openobserve-otel-secret.example.yaml`
- 生产可选组件和信号开关：`infra/production/platform/feature-flags.example.env`
- OpenObserve Gateway API 路由：`infra/production/network/openobserve-route.yaml`
- cert-manager 证书模板：`infra/production/network/certificate.yaml`
- Cloudflare DNS-01 Secret 模板：`infra/production/platform/cloudflare-secret.example.yaml`
- observability/openobserve namespace：`infra/production/observability/namespace.yaml`
- KEDA OpenObserve 接线：`infra/production/autoscaling/keda-openobserve.example.yaml` 和
  `infra/production/autoscaling/openobserve-keda-secret.example.yaml`
- KEDA 通用 RabbitMQ 示例：`infra/production/autoscaling/keda-scaledobject.example.yaml`
- 平台控制器值文件和资源：`infra/production/platform/`
- 生产平台和存储入口：`scripts/production/platform.sh`、`scripts/production/storage.sh`
- K3s 节点 SSH 安装器：`scripts/production/install-node.sh`

这些清单是经过版本固定的起始基线，不是对任意云厂商网络、CSI、S3、OIDC 或容量的
自动适配器。上线前必须在目标云的同规格节点上完成安装、升级、节点替换、备份恢复
和压测验收；验收通过后再把同一套 Git revision 推送到其他节点组。
