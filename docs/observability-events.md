# 可观测性事件规范

本文档定义前端业务事件的稳定名称、属性和数据治理边界。业务组件只调用项目提供的
`telemetry.trackEvent(name, attributes)`，不直接依赖 HyperDX SDK。当前适配器使用
OpenTelemetry custom-action span 承载事件；未来可以替换为原生 OpenTelemetry、其他
后端或空实现，而不修改业务组件。

## 事件目录

| 事件名 | 触发时机 | 必填属性 |
| --- | --- | --- |
| `order.created` | 订单创建成功 | `order.id`、`order.item_id`、`order.quantity` |
| `order.updated` | 订单更新成功 | `order.id`、`order.state` |
| `order.deleted` | 订单删除成功 | `order.id` |
| `catalog.loaded` | 目录和订单列表加载成功 | `catalog.item_count`、`order.item_count` |
| `ui.data.load_failed` | 页面数据加载失败 | `error.message` |
| `ui.demo.action` | 用户点击演示动作按钮 | `ui.action.source`、`ui.action.recorded_at` |
| `ui.session.replay.paused` | 用户暂停会话回放 | 无 |
| `ui.session.replay.resumed` | 用户恢复会话回放 | 无 |

## 属性约定

属性名使用小写点号分隔，优先使用 OpenTelemetry 语义约定；项目属性统一使用领域前缀。

| 属性 | 类型 | 基数 | 个人信息 | 说明 |
| --- | --- | --- | --- | --- |
| `order.id` | string | 高 | 否 | 只进入事件和链路，不进入 Prometheus 标签 |
| `order.item_id` | string | 中 | 否 | 商品标识，不包含用户信息 |
| `order.quantity` | integer | 低 | 否 | 创建时的订单数量 |
| `order.state` | string | 低 | 否 | `created`、`confirmed`、`ready` 或 `cancelled` |
| `catalog.item_count` | integer | 低 | 否 | 页面本次加载的商品数 |
| `order.item_count` | integer | 低 | 否 | 页面本次加载的订单数 |
| `error.message` | string | 不确定 | 可能 | 仅记录可排查信息；不得写入 Cookie、Token、邮箱或请求正文 |
| `ui.session.id` | string | 高 | 否 | 由会话回放 SDK 管理，不作为指标标签 |
| `ui.action.source` | string | 低 | 否 | 固定的界面来源标识 |
| `ui.action.recorded_at` | RFC 3339 string | 高 | 否 | 用于在会话回放中定位动作 |

事件属性可以进入链路、日志或事件存储，但不能直接成为 Prometheus 标签。指标标签必须
来自有限枚举或经过明确聚合的值，例如 `operation`、`result`、`state`；订单 ID、商品 ID、
Session ID、URL 参数和原始错误消息禁止进入指标标签。

## 采样与保留

- 本地演示默认以 100% 采样，便于验收和教学；生产环境应根据 SLO、成本和数据敏感度配置采样。
- 业务事件与链路遵循同一 Trace Context，采样决策由入口和 Collector 统一管理。
- 会话回放默认只用于本地演示。生产环境应单独评估用户授权、遮罩策略、跨境和保留期限。
- 具体后端的保留时间由部署方配置；业务代码不得假设 HyperDX、SigNoz 或 Grafana 的默认保留期。

## 厂商适配边界

`frontend/web/src/telemetry.js` 是当前唯一的浏览器遥测适配边界：

- `HyperDXTelemetryProvider` 负责 HyperDX Browser SDK 和 Session Replay；
- `NoopTelemetryProvider` 在没有 ingestion key 时保证页面仍可用；
- 后续可以增加 `OpenTelemetryTelemetryProvider` 或其他后端 Provider；
- `App.vue` 只能使用 `telemetry` 门面，不得导入厂商 SDK 或调用 `addAction`。

浏览器 ingestion key 是只能访问项目 Collector 的受限密钥，不是后端导出到观测后端的密钥。
Collector 在出口侧使用独立的 `HYPERDX_API_KEY` 或其他 OTLP 后端凭据，并在入口侧完成认证、
CORS、限流、脱敏和批处理。
