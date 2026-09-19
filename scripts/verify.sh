#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROXY_URL="${PROXY_URL:-http://127.0.0.1:7890}"
export HTTP_PROXY="${HTTP_PROXY:-${PROXY_URL}}" HTTPS_PROXY="${HTTPS_PROXY:-${PROXY_URL}}"
export http_proxy="${http_proxy:-${PROXY_URL}}" https_proxy="${https_proxy:-${PROXY_URL}}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,.svc,.cluster.local}"
SUDO=(); [[ ${EUID} -ne 0 ]] && SUDO=(sudo)
if [[ "${MODE:-k3d}" == "k3d" ]]; then
  export KUBECONFIG="$(k3d kubeconfig write "${K3D_CLUSTER_NAME:-gofr-demo}")"
  K=(kubectl)
else
  K=("${SUDO[@]}" k3s kubectl)
fi
NAMESPACE=gofr-demo
HYPERDX_DEMO_EMAIL="${HYPERDX_DEMO_EMAIL:-demo@signal-forge.local}"
HYPERDX_DEMO_PASSWORD="${HYPERDX_DEMO_PASSWORD:-SignalForge#2026}"

TEMP_PIDS=()
TEMP_FILES=()
METRICS_PID=''
cleanup_temp_forwards() {
  for pid in "${TEMP_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  if [[ -n "${METRICS_PID}" ]]; then
    kill "${METRICS_PID}" 2>/dev/null || true
  fi
  for file in "${TEMP_FILES[@]}"; do
    rm -f "${file}"
  done
}
trap cleanup_temp_forwards EXIT
ensure_forward() {
  local url="$1" namespace="$2" service="$3" mapping_string="$4" log_file="$5"
  read -r -a mappings <<< "${mapping_string}"
  if curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1; then
    return
  fi
  "${K[@]}" -n "${namespace}" port-forward "service/${service}" "${mappings[@]}" >"${log_file}" 2>&1 &
  local pid=$!
  TEMP_PIDS+=("${pid}")
  for _ in $(seq 1 20); do
    if curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1; then return; fi
    sleep 0.5
  done
  echo "port-forward did not become ready: ${url}" >&2
  return 1
}

GATEWAY_NAMESPACE=''
GATEWAY_SERVICE=''
for _ in $(seq 1 30); do
  gateway_service_info="$("${K[@]}" get service -A -l gateway.envoyproxy.io/owning-gateway-name=public -o jsonpath='{range .items[0]}{.metadata.namespace} {.metadata.name}{end}' 2>/dev/null || true)"
  read -r GATEWAY_NAMESPACE GATEWAY_SERVICE <<< "${gateway_service_info}"
  [[ -n "${GATEWAY_SERVICE}" ]] && break
  sleep 1
done
[[ -n "${GATEWAY_SERVICE}" ]]
ensure_forward http://127.0.0.1:8080/ "${GATEWAY_NAMESPACE}" "${GATEWAY_SERVICE}" 8080:80 /tmp/envoy-gateway-verify-port-forward.log
ensure_forward http://127.0.0.1:18080/ kube-system kite 18080:8080 /tmp/kite-verify-port-forward.log
ensure_forward http://127.0.0.1:19090/-/ready "${NAMESPACE}" prometheus 19090:9090 /tmp/prometheus-verify-port-forward.log
if [[ "${HYPERDX_MODE:-local}" == "local" ]]; then
  ensure_forward http://localhost:18081/api/health "${NAMESPACE}" hyperdx "18081:8080 14318:4318" /tmp/hyperdx-verify-port-forward.log
  if ! curl --noproxy '*' --silent --max-time 2 http://127.0.0.1:14318/ >/dev/null 2>&1; then
    "${K[@]}" -n "${NAMESPACE}" port-forward service/hyperdx 14318:4318 >/tmp/hyperdx-otlp-verify-port-forward.log 2>&1 &
    TEMP_PIDS+=("$!")
    sleep 1
  fi
  if ! (exec 3<>/dev/tcp/127.0.0.1/14317) 2>/dev/null; then
    "${K[@]}" -n "${NAMESPACE}" port-forward service/hyperdx 14317:4317 >/tmp/hyperdx-grpc-verify-port-forward.log 2>&1 &
    TEMP_PIDS+=("$!")
    sleep 1
  fi
fi

echo '== Kubernetes and Gateway API =='
"${K[@]}" get --raw /apis/metrics.k8s.io/v1beta1 >/dev/null
echo 'metrics-server API: OK'
"${K[@]}" -n kube-system get daemonset/cilium deployment/cilium-operator
if ! cilium_pod="$(${K[@]} -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')" || [[ -z "${cilium_pod}" ]] ||
  ! "${K[@]}" -n kube-system exec "${cilium_pod}" -- cilium-dbg status --brief 2>/dev/null | grep -q '^OK'; then
  echo 'Cilium agent health check failed' >&2
  exit 1
fi
echo 'Cilium agent health: OK'
"${K[@]}" -n envoy-gateway-system get deployment/envoy-gateway
"${K[@]}" get gatewayclass envoy-gateway
"${K[@]}" get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
"${K[@]}" -n "${NAMESPACE}" get gateway public -o wide
"${K[@]}" -n "${NAMESPACE}" get httproute gofr-demo -o wide
envoy_replicas="$(${K[@]} -n envoy-gateway-system get deploy -l gateway.envoyproxy.io/owning-gateway-name=public -o jsonpath='{.items[0].spec.replicas}')"
envoy_ready_replicas="$(${K[@]} -n envoy-gateway-system get deploy -l gateway.envoyproxy.io/owning-gateway-name=public -o jsonpath='{.items[0].status.readyReplicas}')"
[[ "${envoy_replicas}" =~ ^[2-9][0-9]*$ ]] && [[ "${envoy_ready_replicas}" == "${envoy_replicas}" ]]
echo "Envoy Gateway proxy replicas: ${envoy_ready_replicas}/${envoy_replicas}"
"${K[@]}" get gatewayclass envoy-gateway -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' | grep -q 'Accepted=True'
"${K[@]}" -n "${NAMESPACE}" get gateway public -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' | grep -q 'Programmed=True'
"${K[@]}" -n "${NAMESPACE}" get httproute gofr-demo -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}' | grep -q 'Accepted=True'
"${K[@]}" -n "${NAMESPACE}" get deploy,pods,hpa,pdb
"${K[@]}" -n kube-system get deploy/kite
"${K[@]}" -n "${NAMESPACE}" get deploy/prometheus deploy/mysql deploy/redis
if [[ "${HYPERDX_MODE:-local}" == "local" ]]; then
  "${K[@]}" -n "${NAMESPACE}" get deploy/hyperdx
  curl --noproxy '*' --fail --silent http://localhost:18081/api/health >/dev/null
  curl --noproxy '*' --fail --silent -i -X OPTIONS \
    -H 'Origin: http://localhost:18081' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,authorization' \
    http://127.0.0.1:14318/v1/traces | grep -qi 'access-control-allow-origin'
  echo 'HyperDX local UI/API: OK'
  echo 'HyperDX browser OTLP CORS: OK'
fi
curl --noproxy '*' --fail --silent http://127.0.0.1:18080/ >/dev/null
curl --noproxy '*' --fail --silent \
  -H 'x-cluster-name: in-cluster' \
  http://127.0.0.1:18080/api/v1/clusters | grep -q 'in-cluster'
curl --noproxy '*' --fail --silent \
  -H 'x-cluster-name: in-cluster' \
  http://127.0.0.1:18080/api/v1/gateways/_all | grep -q '"kind":"Gateway"'
curl --noproxy '*' --fail --silent http://127.0.0.1:19090/-/ready | grep -q Prometheus
echo 'Kite and Prometheus: OK'
"${K[@]}" -n "${NAMESPACE}" get hpa -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.currentReplicas}{"/"}{.status.desiredReplicas}{"\n"}{end}'
"${K[@]}" -n "${NAMESPACE}" get hpa -o jsonpath='{range .items[*]}{.status.currentReplicas}{"\n"}{end}' | grep -q '[0-9]'

echo '== HTTP and trace-producing request =='
curl --noproxy '*' --fail --silent --show-error http://127.0.0.1:8080/ | grep -q 'id="app"'
catalog_response="$(curl --noproxy '*' --fail --silent --show-error http://127.0.0.1:8080/api/catalog/sku-001)"
printf '%s' "${catalog_response}" | grep -q 'sku-001'
curl --noproxy '*' --fail --silent --show-error http://127.0.0.1:8080/api/catalog/sku-001 | grep -q 'sku-001'
orders_response="$(curl --noproxy '*' --fail --silent --show-error http://127.0.0.1:8080/api/orders)"
printf '%s' "${orders_response}" | grep -q 'item'
create_response="$(curl --noproxy '*' --fail --silent --show-error -H 'content-type: application/json' \
  -d '{"itemId":"sku-001","quantity":1}' http://127.0.0.1:8080/api/orders)"
created_id="$(printf '%s' "${create_response}" | sed -n 's/.*"id":"\([^"]*\)","itemId".*/\1/p')"
[[ -n "${created_id}" ]]
curl --noproxy '*' --fail --silent --show-error -H 'content-type: application/json' \
  -X PATCH -d '{"itemId":"sku-001","quantity":2,"state":"verified"}' \
  "http://127.0.0.1:8080/api/orders/${created_id}" | grep -q 'verified'
delete_status="$(curl --noproxy '*' --silent --show-error -o /dev/null -w '%{http_code}' -X DELETE \
  "http://127.0.0.1:8080/api/orders/${created_id}")"
[[ "${delete_status}" == 204 ]]
echo 'Gateway API end-to-end route: OK'

echo '== GoFr metrics =='
"${K[@]}" -n "${NAMESPACE}" port-forward service/orders 2123:2121 >/tmp/gofr-orders-metrics.log 2>&1 & METRICS_PID=$!
sleep 2
metrics_output="$(mktemp)"
curl --noproxy '*' --fail --silent http://127.0.0.1:2123/metrics -o "${metrics_output}"
grep -q 'app_http_response' "${metrics_output}"
rm -f "${metrics_output}"
echo 'GoFr metrics: OK'

echo '== Prometheus scrape targets =='
prometheus_targets=''
prometheus_metric=''
for _ in $(seq 1 20); do
  prometheus_targets="$(curl --noproxy '*' --silent --show-error --fail \
    --get --data-urlencode 'query=up{job="gofr-services",namespace="gofr-demo"}' \
    http://127.0.0.1:19090/api/v1/query 2>/dev/null || true)"
  prometheus_metric="$(curl --noproxy '*' --silent --show-error --fail \
    --get --data-urlencode 'query=app_http_response_count{job="gofr-services",namespace="gofr-demo"}' \
    http://127.0.0.1:19090/api/v1/query 2>/dev/null || true)"
  if printf '%s' "${prometheus_targets}" | grep -q '"result":\[[^]]' &&
    printf '%s' "${prometheus_metric}" | grep -q '"result":\[[^]]'; then
    break
  fi
  sleep 1
done
printf '%s' "${prometheus_targets}" | grep -q '"result":\[[^]]'
printf '%s' "${prometheus_metric}" | grep -q '"result":\[[^]]'
echo 'Prometheus application targets and GoFr histogram: OK'

echo '== HyperDX Collector =='
collector_tail="$("${K[@]}" -n "${NAMESPACE}" logs deploy/otel-collector --tail=50)"
printf '%s' "${collector_tail}" | grep -qE 'Traces|Metrics|Logs|export' || true
echo 'Collector is running; inspect HyperDX for the trace and session replay.'
if [[ "${HYPERDX_MODE:-local}" == "local" ]]; then
  traces_count='0'
  logs_count='0'
  order_spans_count='0'
  order_query_result=''
  services=''
  for _ in $(seq 1 20); do
    traces_count="$("${K[@]}" -n "${NAMESPACE}" exec deploy/hyperdx -- clickhouse-client --query \
      "SELECT count() FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE" 2>/dev/null | tr -d '[:space:]' || true)"
    logs_count="$("${K[@]}" -n "${NAMESPACE}" exec deploy/hyperdx -- clickhouse-client --query \
      "SELECT count() FROM default.otel_logs WHERE Timestamp > now() - INTERVAL 10 MINUTE" 2>/dev/null | tr -d '[:space:]' || true)"
    services="$("${K[@]}" -n "${NAMESPACE}" exec deploy/hyperdx -- clickhouse-client --query \
      "SELECT groupUniqArray(ServiceName) FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE" 2>/dev/null || true)"
    order_spans_count="$("${K[@]}" -n "${NAMESPACE}" exec deploy/hyperdx -- clickhouse-client --query \
      "SELECT count() FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE AND SpanName IN ('POST /api/orders')" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${traces_count:-0}" =~ ^[0-9]+$ ]] && (( traces_count > 0 )) && \
      [[ "${logs_count:-0}" =~ ^[0-9]+$ ]] && (( logs_count > 0 )) && \
      [[ "${order_spans_count:-0}" =~ ^[0-9]+$ ]] && (( order_spans_count > 0 )) && \
      printf '%s' "${services}" | grep -q 'k3s-gofr-orders' && \
      printf '%s' "${services}" | grep -q 'k3s-gofr-catalog'; then
      break
    fi
    sleep 1
  done
  order_query_result="$("${K[@]}" -n "${NAMESPACE}" exec deploy/hyperdx -- clickhouse-client --query \
    "SELECT SpanName FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE AND SpanName IN ('POST /api/orders') ORDER BY (toDateTime(Timestamp), Timestamp) DESC LIMIT 1" 2>/dev/null || true)"
  [[ "${traces_count:-0}" =~ ^[0-9]+$ ]] && (( traces_count > 0 ))
  [[ "${logs_count:-0}" =~ ^[0-9]+$ ]] && (( logs_count > 0 ))
  [[ "${order_spans_count:-0}" =~ ^[0-9]+$ ]] && (( order_spans_count > 0 ))
  printf '%s' "${order_query_result}" | grep -q '^POST /api/orders$'
  printf '%s' "${services}" | grep -q 'k3s-gofr-orders'
  printf '%s' "${services}" | grep -q 'k3s-gofr-catalog'
  hyperdx_cookie_file="$(mktemp)"
  TEMP_FILES+=("${hyperdx_cookie_file}")
  login_status="$(curl --noproxy '*' --silent --show-error --output /dev/null \
    --cookie-jar "${hyperdx_cookie_file}" --request POST \
    --data-urlencode "email=${HYPERDX_DEMO_EMAIL}" \
    --data-urlencode "password=${HYPERDX_DEMO_PASSWORD}" \
    --write-out '%{http_code}' http://localhost:18081/api/login/password)"
  [[ "${login_status}" == 303 ]]
  connection_id="$(curl --noproxy '*' --fail --silent --cookie "${hyperdx_cookie_file}" \
    http://localhost:18081/api/connections | grep -o '"_id":"[^"]*"' | head -n 1 | cut -d '"' -f 4)"
  [[ -n "${connection_id}" ]]
  hyperdx_ui_query="SELECT SpanName FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 10 MINUTE AND SpanName IN ('POST /api/orders') ORDER BY (toDateTime(Timestamp), Timestamp) DESC LIMIT 1 FORMAT JSON"
  hyperdx_ui_result="$(curl --noproxy '*' --fail --silent --show-error \
    --cookie "${hyperdx_cookie_file}" --request POST \
    --header "x-hyperdx-connection-id: ${connection_id}" \
    --header 'content-type: text/plain' --data-binary "${hyperdx_ui_query}" \
    'http://localhost:18081/api/clickhouse-proxy?format=JSON')"
  printf '%s' "${hyperdx_ui_result}" | grep -q '"rows": 1'
  "${K[@]}" -n "${NAMESPACE}" exec deploy/hyperdx -- clickhouse-client --query \
    "EXISTS TABLE default.hyperdx_sessions" | grep -q '^1$'
  echo "HyperDX stored signals: traces=${traces_count} logs=${logs_count} POST /api/orders=${order_spans_count}; authenticated UI query API: OK; session replay table: OK"
fi
