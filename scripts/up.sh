#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

K3S_VERSION="${K3S_VERSION:-v1.37.2+k3s1}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.7.0}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.4}"
HELM_VERSION="${HELM_VERSION:-v4.3.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.3}"
KURED_VERSION="${KURED_VERSION:-6.1.0}"
SYSTEM_UPGRADE_CONTROLLER_VERSION="${SYSTEM_UPGRADE_CONTROLLER_VERSION:-110.0.0}"
KEDA_VERSION="${KEDA_VERSION:-2.21.0}"
OTEL_OPERATOR_VERSION="${OTEL_OPERATOR_VERSION:-0.129.0}"
NAMESPACE=gofr-demo
CLUSTER_NAME="${K3D_CLUSTER_NAME:-gofr-demo}"
OPENOBSERVE_EMAIL="${OPENOBSERVE_EMAIL:-demo@cloud-native.local}"
OPENOBSERVE_PASSWORD="${OPENOBSERVE_PASSWORD:-CloudNative#2026}"
APP_PORT="${APP_PORT:-8080}"
KITE_PORT="${KITE_PORT:-18080}"
OPENOBSERVE_PORT="${OPENOBSERVE_PORT:-18081}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-19090}"
COLLECTOR_HTTP_PORT="${COLLECTOR_HTTP_PORT:-14318}"
OBSERVABILITY_DASHBOARDS_PROFILE="${OBSERVABILITY_DASHBOARDS_PROFILE:-demo}"
PORT_FORWARD_ADDRESS="${PORT_FORWARD_ADDRESS:-0.0.0.0}"
RUNTIME_DIR="${RUNTIME_DIR:-.runtime}"
PROXY_URL="${PROXY_URL:-http://127.0.0.1:7890}"
# k3d 节点无法访问只监听宿主机回环地址的代理。默认通过宿主机的 PROXY_URL
# 拉取镜像，再导入每个节点。只有 Docker 容器能够访问代理时才设置 NODE_PROXY_URL。
NODE_PROXY_URL="${NODE_PROXY_URL:-}"
mkdir -p "${RUNTIME_DIR}"

# 此脚本负责组装本地环境：创建集群、安装平台控制器、应用分层清单、构建本地镜像，
# 最后只暴露文档中明确列出的端口转发。所有生成文件都放在 RUNTIME_DIR 下，
# 这样 `make down` 可以清理本次部署的进程句柄，而不会触碰无关资源。

# 此脚本的下载使用本地代理。同一个代理也会传给 k3d 节点，供 containerd
# 拉取系统镜像和 chart。
export HTTP_PROXY="${HTTP_PROXY:-${PROXY_URL}}"
export HTTPS_PROXY="${HTTPS_PROXY:-${PROXY_URL}}"
export http_proxy="${http_proxy:-${PROXY_URL}}"
export https_proxy="${https_proxy:-${PROXY_URL}}"
# k3d writes its API endpoint as 0.0.0.0:<ephemeral-port>. Keep all local
# cluster endpoints away from the user's outbound proxy.
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}127.0.0.1,localhost,0.0.0.0,.svc,.cluster.local,172.26.0.0/16"
export no_proxy="${no_proxy:+${no_proxy},}127.0.0.1,localhost,0.0.0.0,.svc,.cluster.local,172.26.0.0/16"

if [[ ${EUID} -ne 0 ]] && ! command -v sudo >/dev/null; then
  echo "安装或运行 k3s 需要 sudo" >&2
  exit 1
fi
SUDO=(); [[ ${EUID} -ne 0 ]] && SUDO=(sudo)

if [[ "${MODE:-k3d}" == "k3d" ]]; then
  if ! command -v k3d >/dev/null; then
    echo "正在安装 k3d"
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  fi
  K3D_K3S_IMAGE="${K3D_K3S_IMAGE:-rancher/k3s:${K3S_VERSION//+/-}}"
  if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
    existing_kubeconfig="$(k3d kubeconfig write "${CLUSTER_NAME}")"
    existing_k3s_version="$(KUBECONFIG="${existing_kubeconfig}" kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)"
    if [[ -n "${existing_k3s_version}" && "${existing_k3s_version}" != "${K3S_VERSION}" ]]; then
      echo "现有 k3d 集群是 ${existing_k3s_version}，目标版本为 ${K3S_VERSION}，将重新创建"
      k3d cluster delete "${CLUSTER_NAME}"
    fi
  fi
  if ! k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
    if ! docker image inspect "${K3D_K3S_IMAGE}" >/dev/null 2>&1; then
      echo "正在拉取 k3s 节点镜像 ${K3D_K3S_IMAGE}"
      docker pull "${K3D_K3S_IMAGE}"
    fi
    k3d_args=(
      cluster create "${CLUSTER_NAME}" --image "${K3D_K3S_IMAGE}" --servers 1 --agents 2 --wait
      --k3s-arg "--flannel-backend=none@server:*"
      --k3s-arg "--disable-network-policy@server:*"
      --k3s-arg "--disable-kube-proxy@server:*"
      --k3s-arg "--disable=traefik@server:*"
      --k3s-arg "--disable=servicelb@server:*"
    )
    if [[ -n "${NODE_PROXY_URL}" ]]; then
      k3d_args+=(
        --env "HTTP_PROXY=${NODE_PROXY_URL}@server:*"
        --env "HTTPS_PROXY=${NODE_PROXY_URL}@server:*"
        --env "NO_PROXY=${NO_PROXY},host.k3d.internal@server:*"
        --env "HTTP_PROXY=${NODE_PROXY_URL}@agent:*"
        --env "HTTPS_PROXY=${NODE_PROXY_URL}@agent:*"
        --env "NO_PROXY=${NO_PROXY},host.k3d.internal@agent:*"
      )
    fi
    k3d "${k3d_args[@]}"
  fi
  KUBECONFIG_PATH="$(k3d kubeconfig write "${CLUSTER_NAME}")"
  export KUBECONFIG="${KUBECONFIG_PATH}"
  if ! command -v kubectl >/dev/null; then
    echo "正在安装 kubectl 客户端"
    KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
    "${SUDO[@]}" install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl
  fi
  KUBECTL=(kubectl)
else
  if ! command -v k3s >/dev/null; then
    echo "正在安装 k3s ${K3S_VERSION}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server --write-kubeconfig-mode 644
  fi
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
  KUBECTL=("${SUDO[@]}" k3s kubectl)
fi
echo "正在等待 Kubernetes API"
until "${KUBECTL[@]}" get nodes >/dev/null 2>&1; do sleep 2; done

ensure_helm() {
  if command -v helm >/dev/null; then
    local installed_helm
    installed_helm="$(helm version --short 2>/dev/null | sed -E 's/^([^+]+).*/\1/' || true)"
    if [[ "${installed_helm}" == "${HELM_VERSION}" ]]; then
      return
    fi
    echo "正在将 Helm ${installed_helm:-unknown} 升级到 ${HELM_VERSION}"
  fi
  local archive="/tmp/helm-${HELM_VERSION}.tar.gz"
  echo "正在安装 Helm ${HELM_VERSION}"
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o "${archive}"
  tar -xzf "${archive}" -C /tmp
  "${SUDO[@]}" install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
  rm -rf "${archive}" /tmp/linux-amd64
}

ensure_helm

if [[ "${MODE:-k3d}" == "k3d" ]]; then
  import_system_image() {
    local image="$1"
    local archive="/tmp/k3d-$(echo "${image}" | tr '/:' '__').tar"
    echo "正在准备节点镜像 ${image}"
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
      docker pull "${image}"
    else
      echo "使用本地镜像 ${image}"
    fi
    docker save -o "${archive}" "${image}"
    while read -r node; do
      [[ -z "${node}" ]] && continue
      if docker exec "${node}" ctr -n k8s.io images list -q 2>/dev/null | grep -Fxq "${image}"; then
        echo "节点 ${node} 已有镜像 ${image}"
        continue
      fi
      docker cp "${archive}" "${node}:/tmp/k3d-image.tar"
      docker exec "${node}" ctr -n k8s.io images import /tmp/k3d-image.tar >/dev/null
    done < <(docker ps --format '{{.Names}}' | grep -E "^k3d-${CLUSTER_NAME}-(server|agent)-")
    rm -f "${archive}"
  }
  for system_image in \
    rancher/mirrored-pause:3.10.2 \
    rancher/mirrored-coredns-coredns:1.15.0 \
    rancher/local-path-provisioner:v0.0.37 \
    rancher/mirrored-metrics-server:v0.9.1 \
    rancher/klipper-helm:v0.13.3-build20261021 \
    rancher/mirrored-library-busybox:1.38.0 \
    quay.io/cilium/cilium:v${CILIUM_VERSION} \
    quay.io/cilium/operator-generic:v${CILIUM_VERSION} \
    quay.io/cilium/cilium-envoy:v1.39.5-1792733054-8c73b2816bc8239e27f1fd53b271884688137459 \
    ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator:0.162.0 \
    ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.162.0 \
    prom/prometheus:v3.16.0 \
    otel/opentelemetry-collector-contrib:0.162.0 \
    postgres:18.6-alpine3.24 \
    mysql:8.4.13 \
    redis:8.8.4-alpine3.23 \
    nginx:1.31.8-alpine3.24 \
    o2cr.ai/openobserve/openobserve:v1.1.2 \
    ghcr.io/kite-org/kite:v0.16.0; do
    import_system_image "${system_image}"
  done
  import_namespace_images() {
    local namespace="$1"
    while read -r image; do
      [[ -z "${image:-}" ]] && continue
      import_system_image "${image}"
    done < <(
      {
        "${KUBECTL[@]}" -n "${namespace}" get pods,deploy,daemonset -o jsonpath='{range .items[*].spec.template.spec.containers[*]}{.image}{"\n"}{end}' 2>/dev/null
        "${KUBECTL[@]}" -n "${namespace}" get pods -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' 2>/dev/null
      } | sort -u
    )
  }
fi

SERVER_IP="$("${KUBECTL[@]}" get node "k3d-${CLUSTER_NAME}-server-0" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
  --version "${CILIUM_VERSION}" --namespace kube-system --create-namespace \
  -f infra/network/cilium-values.yaml \
  --set "k8sServiceHost=${SERVER_IP}" --set k8sServicePort=6443
"${KUBECTL[@]}" -n kube-system rollout status daemonset/cilium --timeout=300s
"${KUBECTL[@]}" -n kube-system rollout status deployment/cilium-operator --timeout=300s

# Namespaces are created before any controller-owned resources reference them.
"${KUBECTL[@]}" apply -f infra/k3s/namespace.yaml
"${KUBECTL[@]}" apply -f infra/production/platform/namespaces.yaml -f infra/production/observability/namespace.yaml

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add kured https://kubereboot.github.io/charts >/dev/null 2>&1 || true
helm repo add rancher https://charts.rancher.io >/dev/null 2>&1 || true
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update jetstack kured rancher kedacore >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager --version "${CERT_MANAGER_VERSION}" \
  --namespace cert-manager --create-namespace -f infra/production/platform/cert-manager-values.yaml
[[ "${MODE:-k3d}" == "k3d" ]] && import_namespace_images cert-manager || true
"${KUBECTL[@]}" -n cert-manager rollout status deployment/cert-manager --timeout=300s
"${KUBECTL[@]}" -n cert-manager rollout status deployment/cert-manager-webhook --timeout=300s
"${KUBECTL[@]}" -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=300s
if [[ "${MODE:-k3d}" == "k3d" ]]; then
  # The preview cluster must not register an ACME account with a placeholder
  # domain. It uses a self-signed issuer to exercise cert-manager wiring.
  "${KUBECTL[@]}" apply -f infra/observability/cert-manager-preview.yaml
else
  # Production renders this file with a real ACME email and DNS provider
  # Secret through the external secret manager before applying it.
  "${KUBECTL[@]}" apply -f infra/production/platform/issuers.yaml
fi

helm upgrade --install kured kured/kured --version "${KURED_VERSION}" \
  --namespace kured --create-namespace -f infra/production/platform/kured-values.yaml
[[ "${MODE:-k3d}" == "k3d" ]] && import_namespace_images kured || true
"${KUBECTL[@]}" -n kured rollout status daemonset/kured --timeout=300s

# The SUC chart keeps its controller objects in cattle-system even when the
# Helm release itself is named in system-upgrade. Create that target namespace
# before server-side apply runs.
"${KUBECTL[@]}" create namespace cattle-system --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
helm upgrade --install system-upgrade-controller rancher/system-upgrade-controller \
  --version "${SYSTEM_UPGRADE_CONTROLLER_VERSION}" --namespace system-upgrade --create-namespace \
  -f infra/production/platform/system-upgrade-controller-values.yaml
[[ "${MODE:-k3d}" == "k3d" ]] && import_namespace_images system-upgrade || true
[[ "${MODE:-k3d}" == "k3d" ]] && import_namespace_images cattle-system || true
"${KUBECTL[@]}" -n cattle-system rollout status deployment/system-upgrade-controller --timeout=300s
"${KUBECTL[@]}" apply -f infra/production/platform/system-upgrade-plans.yaml

KEDA_VALUES=infra/production/platform/keda-values.yaml
[[ "${MODE:-k3d}" == "k3d" ]] && KEDA_VALUES=infra/observability/keda-preview-values.yaml
helm upgrade --install keda kedacore/keda --version "${KEDA_VERSION}" \
  --namespace keda --create-namespace -f infra/production/platform/keda-values.yaml -f "${KEDA_VALUES}"
[[ "${MODE:-k3d}" == "k3d" ]] && import_namespace_images keda || true
"${KUBECTL[@]}" -n keda rollout status deployment/keda-operator --timeout=300s
"${KUBECTL[@]}" -n keda rollout status deployment/keda-admission-webhooks --timeout=300s

"${KUBECTL[@]}" apply --server-side --force-conflicts -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --version "${OTEL_OPERATOR_VERSION}" --namespace opentelemetry-operator-system --create-namespace \
  -f infra/production/platform/otel-operator-values.yaml
[[ "${MODE:-k3d}" == "k3d" ]] && import_namespace_images opentelemetry-operator-system || true
"${KUBECTL[@]}" -n opentelemetry-operator-system rollout status deployment/opentelemetry-operator --timeout=300s
"${KUBECTL[@]}" -n "${NAMESPACE}" delete deployment/otel-collector service/otel-collector configmap/otel-collector-config --ignore-not-found
BROWSER_API_KEY="${VITE_OTEL_INGESTION_KEY:-k3s-gofr-browser-ingestion}"
OPENOBSERVE_AUTH="Basic $(printf '%s:%s' "${OPENOBSERVE_EMAIL}" "${OPENOBSERVE_PASSWORD}" | base64 -w0)"
printf '%s' "${BROWSER_API_KEY}" > "${RUNTIME_DIR}/browser-ingestion-key"
chmod 600 "${RUNTIME_DIR}/browser-ingestion-key"
"${KUBECTL[@]}" create secret generic openobserve-local -n "${NAMESPACE}" \
  --from-literal=root-user-email="${OPENOBSERVE_EMAIL}" \
  --from-literal=root-user-password="${OPENOBSERVE_PASSWORD}" \
  --from-literal=authorization="${OPENOBSERVE_AUTH}" \
  --from-literal=browser-api-key="${BROWSER_API_KEY}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" apply -f infra/observability/openobserve.yaml -f infra/observability/config.yaml -f infra/observability/collector-operator.yaml
"${KUBECTL[@]}" apply -f infra/observability/prometheus-rules.yaml -f infra/observability/prometheus.yaml
"${KUBECTL[@]}" apply -f infra/data/postgres.yaml -f infra/data/mysql-redis.yaml
"${KUBECTL[@]}" apply -f infra/apps/services.yaml -f infra/apps/autoscaling.yaml
"${KUBECTL[@]}" -n "${NAMESPACE}" delete hpa orders --ignore-not-found
"${KUBECTL[@]}" create secret generic openobserve-keda -n "${NAMESPACE}" \
  --from-literal=username="${OPENOBSERVE_EMAIL}" \
  --from-literal=password="${OPENOBSERVE_PASSWORD}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" apply -f infra/observability/keda-openobserve.yaml
if [[ "${MODE:-k3d}" == "k3d" ]]; then
  "${KUBECTL[@]}" apply -f infra/network/cilium-lbipam-preview.yaml
fi
"${KUBECTL[@]}" apply -f infra/network/gateway.yaml

if command -v helm >/dev/null; then
  helm upgrade --install kite oci://ghcr.io/kite-org/charts/kite --namespace kube-system --create-namespace -f infra/dashboard/kite.yaml
else
  echo "未安装 Helm，将应用本地 Kite 回退清单"
  "${KUBECTL[@]}" apply -f infra/dashboard/kite-fallback.yaml
fi
if ! command -v docker >/dev/null; then
  echo "构建本地镜像需要 Docker" >&2
  exit 1
fi
GO_BUILD_CACHE="${GOCACHE:-${PWD}/${RUNTIME_DIR}/go-cache}"
(cd services && GOCACHE="${GO_BUILD_CACHE}" CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "../${RUNTIME_DIR}/catalog" ./catalog)
(cd services && GOCACHE="${GO_BUILD_CACHE}" CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "../${RUNTIME_DIR}/orders" ./orders)
docker build -f services/Dockerfile.runtime --build-arg SERVICE=catalog -t k3s-gofr/catalog:dev .
docker build -f services/Dockerfile.runtime --build-arg SERVICE=orders -t k3s-gofr/orders:dev .
(
  cd frontend/web
  VITE_OTEL_INGESTION_KEY="${BROWSER_API_KEY}" \
  VITE_OTEL_INGESTION_URL="${VITE_OTEL_INGESTION_URL:-}" \
  pnpm install --frozen-lockfile
  VITE_OTEL_INGESTION_KEY="${BROWSER_API_KEY}" \
  VITE_OTEL_INGESTION_URL="${VITE_OTEL_INGESTION_URL:-}" pnpm build
)
docker build \
  -t k3s-gofr/web:dev frontend/web
if [[ "${MODE:-k3d}" == "k3d" ]]; then
  k3d image import -c "${CLUSTER_NAME}" k3s-gofr/catalog:dev k3s-gofr/orders:dev k3s-gofr/web:dev
else
  docker save k3s-gofr/catalog:dev k3s-gofr/orders:dev k3s-gofr/web:dev | "${SUDO[@]}" k3s ctr images import -
fi

# 演示使用可变的本地 :dev 标签；重启应用 Pod，确保每次执行都加载刚构建的二进制和前端 bundle。
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout restart deploy/catalog deploy/orders deploy/web
# Prometheus 从挂载的 ConfigMap 读取配置和 recording rule。应用这些 ConfigMap 后重启，
# 确保重复执行 `make up` 时配置和镜像都能生效。
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout restart deploy/prometheus

"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/catalog --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/orders --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/web --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/openobserve --timeout=360s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/prometheus --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/postgres --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/mysql --timeout=240s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/redis --timeout=180s
"${KUBECTL[@]}" -n kube-system rollout status deploy/kite --timeout=180s
"${KUBECTL[@]}" -n gofr-demo wait gateway/public --for=condition=Programmed --timeout=180s

import_pod_images() {
  local namespace="$1"
  while read -r image; do
    [[ -z "${image}" ]] && continue
    import_system_image "${image}"
  done < <("${KUBECTL[@]}" -n "${namespace}" get pods -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' | sort -u)
}
if [[ "${MODE:-k3d}" == "k3d" ]]; then
  import_pod_images gofr-demo
fi
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/gateway-collector --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status daemonset/agent-collector --timeout=180s

GATEWAY_NAMESPACE=''
GATEWAY_SERVICE=''
until read -r GATEWAY_NAMESPACE GATEWAY_SERVICE < <("${KUBECTL[@]}" get service -A -l gateway.networking.k8s.io/gateway-name=public -o jsonpath='{range .items[0]}{.metadata.namespace} {.metadata.name}{end}' 2>/dev/null); [[ -n "${GATEWAY_SERVICE}" ]]; do
  sleep 2
done
"${KUBECTL[@]}" -n gofr-demo wait gateway/public --for=condition=Programmed --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" wait gateway/public --for=condition=Programmed --timeout=120s

start_forward() {
  local url="$1" namespace="$2" service="$3" mapping_string="$4" pid_file="$5" log_file="$6"
  read -r -a mappings <<< "${mapping_string}"
  # 上一次 Shell 可能留下仍在工作的端口转发和过期 PID 文件。只有 PID 文件
  # 明确指向本脚本创建的进程时才复用，避免把宿主机上另一个 Prometheus/UI
  # 误当成当前集群的端点。
  if [[ -f "${pid_file}" ]]; then
    local previous_pid
    previous_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${previous_pid}" ]] && kill -0 "${previous_pid}" 2>/dev/null \
      && ps -p "${previous_pid}" -o args= 2>/dev/null | grep -Eq '([k]ubectl.*port-forward|[s]ocat .*TCP-LISTEN:)'; then
      if [[ -z "${url}" ]]; then
        return
      fi
      kill "${previous_pid}" 2>/dev/null || true
      sleep 0.2
    fi
    rm -f "${pid_file}"
  fi
  if [[ -n "${url}" ]] && curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1; then
    echo "端口 ${mappings[0]%%:*} 已被其他进程占用：${url}" >&2
    return 1
  fi
  setsid sh -c 'exec "$@"' sh "${KUBECTL[@]}" -n "${namespace}" port-forward --address "${PORT_FORWARD_ADDRESS}" "service/${service}" "${mappings[@]}" >"${log_file}" 2>&1 &
  echo $! >"${pid_file}"
  if [[ -z "${url}" ]]; then
    local local_port="${mappings[0]%%:*}"
    for _ in $(seq 1 30); do
      if ! kill -0 "$!" 2>/dev/null; then
        echo "端口转发进程已退出：${namespace}/${service}；请查看 ${log_file}" >&2
        return 1
      fi
      if (exec 3<>"/dev/tcp/127.0.0.1/${local_port}") 2>/dev/null; then
        exec 3>&-
        return
      fi
      sleep 0.5
    done
    echo "端口转发未监听：127.0.0.1:${local_port}；请查看 ${log_file}" >&2
    return 1
  fi
  if [[ -n "${url}" ]]; then
    for _ in $(seq 1 30); do
      if curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1; then
        return
      fi
      sleep 0.5
    done
    echo "端口转发未就绪：${url}；请查看 ${log_file}" >&2
    return 1
  fi
}

start_gateway_forward() {
  local url="$1" namespace="$2" service="$3" mapping_string="$4" pid_file="$5" log_file="$6"
  local service_selector node_ip node_port
  service_selector="$("${KUBECTL[@]}" -n "${namespace}" get service "${service}" -o jsonpath='{.spec.selector}' 2>/dev/null || true)"
  if [[ -n "${service_selector}" && "${service_selector}" != "map[]" ]]; then
    start_forward "${url}" "${namespace}" "${service}" "${mapping_string}" "${pid_file}" "${log_file}"
    return
  fi

  # Cilium Gateway Services intentionally have no selector: Cilium programs
  # the dataplane directly. Port-forward cannot attach to such a Service, so
  # the k3d preview bridges its NodePort to the documented localhost port.
  node_port="$("${KUBECTL[@]}" -n "${namespace}" get service "${service}" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
  node_ip="${SERVER_IP:-$("${KUBECTL[@]}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}') }"
  [[ -n "${node_port}" && -n "${node_ip}" ]] || { echo "无法为无 selector 的 Gateway Service 找到 NodePort：${namespace}/${service}" >&2; return 1; }
  read -r -a mappings <<< "${mapping_string}"
  local local_port="${mappings[0]%%:*}"
  if [[ -f "${pid_file}" ]]; then
    local previous_pid; previous_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${previous_pid}" ]] && kill -0 "${previous_pid}" 2>/dev/null \
      && ps -p "${previous_pid}" -o args= 2>/dev/null | grep -q '[s]ocat .*TCP-LISTEN:'; then
      return
    fi
    if [[ -n "${previous_pid}" ]] && kill -0 "${previous_pid}" 2>/dev/null; then kill "${previous_pid}" 2>/dev/null || true; sleep 0.2; fi
    rm -f "${pid_file}"
  fi
  # Recover a live bridge if an earlier run was interrupted after starting
  # socat but before persisting its PID.
  if existing_bridge="$(pgrep -f "socat TCP-LISTEN:${local_port}," | head -n1 || true)"; [[ -n "${existing_bridge}" ]]; then
    echo "${existing_bridge}" >"${pid_file}"
    return
  fi
  if curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1; then
    echo "端口 ${local_port} 已被其他进程占用：${url}" >&2
    return 1
  fi
  setsid socat "TCP-LISTEN:${local_port},bind=127.0.0.1,reuseaddr,fork" "TCP:${node_ip}:${node_port}" >"${log_file}" 2>&1 &
  echo $! >"${pid_file}"
  for _ in $(seq 1 30); do
    if curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1; then return; fi
    sleep 0.5
  done
  echo "Gateway NodePort 转发未就绪：${url} -> ${node_ip}:${node_port}；请查看 ${log_file}" >&2
  return 1
}

start_gateway_forward "http://127.0.0.1:${APP_PORT}/" "${GATEWAY_NAMESPACE}" "${GATEWAY_SERVICE}" "${APP_PORT}:80" "${RUNTIME_DIR}/port-forward.pid" "${RUNTIME_DIR}/port-forward.log"
start_forward "http://127.0.0.1:${KITE_PORT}/" kube-system kite "${KITE_PORT}:8080" "${RUNTIME_DIR}/kite-port-forward.pid" "${RUNTIME_DIR}/kite-port-forward.log"
start_forward "http://127.0.0.1:${PROMETHEUS_PORT}/-/ready" "${NAMESPACE}" prometheus "${PROMETHEUS_PORT}:9090" "${RUNTIME_DIR}/prometheus-port-forward.pid" "${RUNTIME_DIR}/prometheus-port-forward.log"
echo "业务入口已就绪：http://127.0.0.1:${APP_PORT}/"
echo "Kite：http://127.0.0.1:${KITE_PORT}/"
echo "Prometheus：http://127.0.0.1:${PROMETHEUS_PORT}/"
start_forward "http://localhost:${OPENOBSERVE_PORT}/healthz" "${NAMESPACE}" openobserve "${OPENOBSERVE_PORT}:5080" "${RUNTIME_DIR}/openobserve-port-forward.pid" "${RUNTIME_DIR}/openobserve-port-forward.log"
start_forward '' "${NAMESPACE}" gateway-collector "${COLLECTOR_HTTP_PORT}:4318" "${RUNTIME_DIR}/collector-http-port-forward.pid" "${RUNTIME_DIR}/collector-http-port-forward.log"
OPENOBSERVE_URL="http://127.0.0.1:${OPENOBSERVE_PORT}" \
  OPENOBSERVE_EMAIL="${OPENOBSERVE_EMAIL}" \
  OPENOBSERVE_PASSWORD="${OPENOBSERVE_PASSWORD}" \
  OBSERVABILITY_DASHBOARDS_PROFILE="${OBSERVABILITY_DASHBOARDS_PROFILE}" \
  OBSERVABILITY_DEMO_APP_ENABLED=true \
  scripts/observability/apply-dashboards.sh
echo "OpenObserve：http://localhost:${OPENOBSERVE_PORT}/"
echo "浏览器 OTLP 接入：http://127.0.0.1:${COLLECTOR_HTTP_PORT}/（经 Gateway 使用时无需直接访问此端口）"
