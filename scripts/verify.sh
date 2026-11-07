#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "${MODE:-k3d}" == "k3d" ]]; then
  export KUBECONFIG="$(k3d kubeconfig write "${K3D_CLUSTER_NAME:-gofr-demo}")"
  K=(kubectl)
else
  SUDO=(); [[ ${EUID} -ne 0 ]] && SUDO=(sudo)
  K=("${SUDO[@]}" k3s kubectl)
fi
# k3d writes its API endpoint as 0.0.0.0:<ephemeral-port>; do not send local
# Kubernetes traffic through a configured outbound proxy.
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}127.0.0.1,localhost,0.0.0.0,.svc,.cluster.local,172.26.0.0/16"
export no_proxy="${no_proxy:+${no_proxy},}127.0.0.1,localhost,0.0.0.0,.svc,.cluster.local,172.26.0.0/16"
NAMESPACE=gofr-demo
RUNTIME_DIR="${RUNTIME_DIR:-.runtime}"
APP_PORT="${APP_PORT:-8080}"
OPENOBSERVE_PORT="${OPENOBSERVE_PORT:-18081}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-19090}"
APP_URL="http://127.0.0.1:${APP_PORT}"
OPENOBSERVE_URL="http://localhost:${OPENOBSERVE_PORT}"
PROMETHEUS_URL="http://127.0.0.1:${PROMETHEUS_PORT}"
OPENOBSERVE_EMAIL="${OPENOBSERVE_EMAIL:-demo@cloud-native.local}"
OPENOBSERVE_PASSWORD="${OPENOBSERVE_PASSWORD:-CloudNative#2026}"
BROWSER_INGESTION_KEY="${VITE_OTEL_INGESTION_KEY:-$(cat "${RUNTIME_DIR}/browser-ingestion-key" 2>/dev/null || printf '%s' k3s-gofr-browser-ingestion)}"
TEMP_PIDS=()
cleanup() { for pid in "${TEMP_PIDS[@]}"; do kill "${pid}" 2>/dev/null || true; done; }
trap cleanup EXIT

forward() {
  local url="$1" namespace="$2" service="$3" mapping="$4" log="$5"
  if curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1; then return; fi
  "${K[@]}" -n "${namespace}" port-forward --address 127.0.0.1 "service/${service}" "${mapping}" >"${log}" 2>&1 &
  local pid=$!; TEMP_PIDS+=("${pid}")
  for _ in $(seq 1 30); do
    curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1 && return
    sleep 0.5
  done
  echo "端口转发未就绪：${url}" >&2; return 1
}

forward_gateway() {
  local url="$1" namespace="$2" service="$3" mapping="$4" log="$5"
  local selector node_port node_ip local_port
  selector="$("${K[@]}" -n "${namespace}" get service "${service}" -o jsonpath='{.spec.selector}' 2>/dev/null || true)"
  if [[ -n "${selector}" && "${selector}" != "map[]" ]]; then
    forward "${url}" "${namespace}" "${service}" "${mapping}" "${log}"
    return
  fi
  node_port="$("${K[@]}" -n "${namespace}" get service "${service}" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
  node_ip="$("${K[@]}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  local_port="${mapping%%:*}"
  [[ -n "${node_port}" && -n "${node_ip}" ]] || { echo "无法为 Gateway Service 找到 NodePort" >&2; return 1; }
  if curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1; then return; fi
  socat "TCP-LISTEN:${local_port},bind=127.0.0.1,reuseaddr,fork" "TCP:${node_ip}:${node_port}" >"${log}" 2>&1 &
  local pid=$!; TEMP_PIDS+=("${pid}")
  for _ in $(seq 1 30); do
    curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1 && return
    sleep 0.5
  done
  echo "Gateway NodePort 转发未就绪：${url}" >&2; return 1
}

gateway_service="$("${K[@]}" -n "${NAMESPACE}" get service -l gateway.networking.k8s.io/gateway-name=public -o jsonpath='{range .items[0]}{.metadata.name}{end}')"
[[ -n "${gateway_service}" ]] || { echo 'Cilium Gateway Service 不存在' >&2; exit 1; }
forward_gateway "${APP_URL}/" "${NAMESPACE}" "${gateway_service}" "${APP_PORT}:80" /tmp/preview-gateway-verify.log
forward "${PROMETHEUS_URL}/-/ready" "${NAMESPACE}" prometheus "${PROMETHEUS_PORT}:9090" /tmp/preview-prometheus-verify.log
forward "${OPENOBSERVE_URL}/healthz" "${NAMESPACE}" openobserve "${OPENOBSERVE_PORT}:5080" /tmp/preview-openobserve-verify.log

echo '== 控制器与资源 =='
"${K[@]}" get nodes
"${K[@]}" -n cert-manager get deploy
"${K[@]}" -n kured get daemonset kured
"${K[@]}" -n cattle-system get deploy system-upgrade-controller
"${K[@]}" -n keda get deploy keda-operator keda-admission-webhooks
"${K[@]}" -n opentelemetry-operator-system get deploy opentelemetry-operator
"${K[@]}" -n gofr-demo get opentelemetrycollector
"${K[@]}" get clusterissuer preview-selfsigned
"${K[@]}" -n gofr-demo get certificate preview-gateway

echo '== OpenObserve 健康与认证 =='
curl --noproxy '*' --fail --silent "${OPENOBSERVE_URL}/healthz" >/dev/null
curl --noproxy '*' --fail --silent -u "${OPENOBSERVE_EMAIL}:${OPENOBSERVE_PASSWORD}" "${OPENOBSERVE_URL}/api/default/streams" >/dev/null

echo '== 业务请求与浏览器 OTLP =='
curl --noproxy '*' --fail --silent "${APP_URL}/" | grep -q 'id="app"'
curl --noproxy '*' --fail --silent "${APP_URL}/api/catalog/sku-001" | grep -q sku-001
curl --noproxy '*' --fail --silent "${APP_URL}/api/orders" | grep -q item
curl --noproxy '*' --fail --silent -i -X OPTIONS \
  -H "Origin: http://localhost:${APP_PORT}" \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type,authorization' \
  "${APP_URL}/v1/traces" | grep -qi access-control-allow-origin
[[ "$(curl --noproxy '*' --silent -o /dev/null -w '%{http_code}' -X POST -H content-type:application/json -d '{"resourceSpans":[]}' "${APP_URL}/v1/traces")" == 401 ]]
[[ "$(curl --noproxy '*' --silent -o /dev/null -w '%{http_code}' -X POST -H "authorization: Bearer ${BROWSER_INGESTION_KEY}" -H content-type:application/json -d '{"resourceSpans":[]}' "${APP_URL}/v1/traces")" =~ ^2[0-9][0-9]$ ]]

echo '== OpenObserve 三类信号 =='
now_us="$(date +%s000000)"; start_us="$((now_us - 900000000))"
OPENOBSERVE_AUTH="${OPENOBSERVE_EMAIL}:${OPENOBSERVE_PASSWORD}"
search() {
  local sql="$1"
  curl --noproxy '*' --fail --silent --user "${OPENOBSERVE_AUTH}" \
    -H 'content-type: application/json' -X POST "${OPENOBSERVE_URL}/api/default/_search" \
    -d "$(jq -cn --arg sql "${sql}" --argjson start "${start_us}" --argjson end "${now_us}" '{query:{sql:$sql,start_time:$start,end_time:$end,from:0,size:1}}')"
}
traces="$(search 'SELECT COUNT(*) AS total FROM "default"' | jq -r '.hits[0].total // .result[0].total // .total // 0')"
logs="$(search 'SELECT COUNT(*) AS total FROM "default"' | jq -r '.hits[0].total // .result[0].total // .total // 0')"
traces="$(curl --noproxy '*' --fail --silent --user "${OPENOBSERVE_AUTH}" \
  -H 'content-type: application/json' -X POST "${OPENOBSERVE_URL}/api/default/_search?type=traces" \
  -d "$(jq -cn --arg sql 'SELECT COUNT(*) AS total FROM "default"' --argjson start "${start_us}" --argjson end "${now_us}" '{query:{sql:$sql,start_time:$start,end_time:$end,from:0,size:1}}')" \
  | jq -r '.hits[0].total // 0')"
logs="$(curl --noproxy '*' --fail --silent --user "${OPENOBSERVE_AUTH}" \
  -H 'content-type: application/json' -X POST "${OPENOBSERVE_URL}/api/default/_search?type=logs" \
  -d "$(jq -cn --arg sql 'SELECT COUNT(*) AS total FROM "default"' --argjson start "${start_us}" --argjson end "${now_us}" '{query:{sql:$sql,start_time:$start,end_time:$end,from:0,size:1}}')" \
  | jq -r '.hits[0].total // 0')"
metrics="$(curl --noproxy '*' --fail --silent --user "${OPENOBSERVE_AUTH}" \
  -H 'content-type: application/x-www-form-urlencoded' -X POST \
  "${OPENOBSERVE_URL}/api/default/prometheus/api/v1/query" --data-urlencode 'query=up' \
  | jq '[.data.result[]? | select(.value[1] != "0")] | length')"
[[ "${traces}" =~ ^[0-9]+$ ]] && (( traces > 0 ))
[[ "${logs}" =~ ^[0-9]+$ ]] && (( logs > 0 ))
[[ "${metrics}" =~ ^[0-9]+$ ]] && (( metrics > 0 ))
echo "OpenObserve metrics/logs/traces：正常（traces=${traces}, logs=${logs}, metric_streams=${metrics}）"

echo '== HPA/KEDA =='
"${K[@]}" -n "${NAMESPACE}" get scaledobject,triggerauthentication,hpa
echo '完整集群验收：通过'
