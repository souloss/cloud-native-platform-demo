#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

K3S_VERSION="${K3S_VERSION:-v1.37.0+k3s1}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.9.1}"
HELM_VERSION="${HELM_VERSION:-v3.19.0}"
NAMESPACE=gofr-demo
CLUSTER_NAME="${K3D_CLUSTER_NAME:-gofr-demo}"
HYPERDX_MODE="${HYPERDX_MODE:-local}"
HYPERDX_DEMO_EMAIL="${HYPERDX_DEMO_EMAIL:-demo@cloud-native.local}"
HYPERDX_DEMO_PASSWORD="${HYPERDX_DEMO_PASSWORD:-CloudNative#2026}"
PROXY_URL="${PROXY_URL:-http://127.0.0.1:7890}"
# k3d 节点无法访问只监听宿主机回环地址的代理。默认通过宿主机的 PROXY_URL
# 拉取镜像，再导入每个节点。只有 Docker 容器能够访问代理时才设置 NODE_PROXY_URL。
NODE_PROXY_URL="${NODE_PROXY_URL:-}"
mkdir -p .runtime

# 此脚本负责组装本地环境：创建集群、安装平台控制器、应用分层清单、构建本地镜像，
# 最后只暴露文档中明确列出的端口转发。所有生成文件都放在 .runtime/ 下，
# 这样 `make down` 可以清理进程句柄，而不会触碰无关的 Docker 或 Kubernetes 资源。

# 此脚本的下载使用本地代理。同一个代理也会传给 k3d 节点，供 containerd
# 拉取系统镜像和 chart。
export HTTP_PROXY="${HTTP_PROXY:-${PROXY_URL}}"
export HTTPS_PROXY="${HTTPS_PROXY:-${PROXY_URL}}"
export http_proxy="${http_proxy:-${PROXY_URL}}"
export https_proxy="${https_proxy:-${PROXY_URL}}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,.svc,.cluster.local}"

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
    if ! KUBECONFIG="${existing_kubeconfig}" kubectl get daemonset cilium -n kube-system >/dev/null 2>&1; then
      echo "现有 k3d 集群不是 Cilium 集群，将启用 Cilium 重新创建"
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
    return
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
    local envoy_repo_digest=''
    echo "正在准备节点镜像 ${image}"
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
      docker pull "${image}"
    else
      echo "使用本地镜像 ${image}"
    fi
    docker save -o "${archive}" "${image}"
    while read -r node; do
      [[ -z "${node}" ]] && continue
      docker cp "${archive}" "${node}:/tmp/k3d-image.tar"
      docker exec "${node}" ctr -n k8s.io images import /tmp/k3d-image.tar >/dev/null
      # Envoy Gateway 通过多架构 manifest digest 固定数据面镜像。只导入标签不足以
      # 满足 containerd 的 CRI 解析器，因此要同时保留 digest 别名。
      if [[ "${image}" == docker.io/envoyproxy/envoy:* ]]; then
        envoy_repo_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)"
        if [[ -n "${envoy_repo_digest}" ]]; then
          docker exec "${node}" ctr -n k8s.io images tag "${image}" "docker.io/${envoy_repo_digest#docker.io/}" >/dev/null 2>&1 || true
        fi
      fi
    done < <(docker ps --format '{{.Names}}' | grep -E "^k3d-${CLUSTER_NAME}-(server|agent)-")
    rm -f "${archive}"
  }
  for system_image in \
    rancher/mirrored-pause:3.10.2 \
    rancher/mirrored-coredns-coredns:1.14.7 \
    rancher/local-path-provisioner:v0.0.37 \
    rancher/mirrored-metrics-server:v0.9.0 \
    rancher/klipper-helm:v0.13.3-build20260727 \
    rancher/mirrored-library-busybox:1.37.0 \
    quay.io/cilium/cilium:v${CILIUM_VERSION} \
    quay.io/cilium/operator-generic:v${CILIUM_VERSION} \
    quay.io/cilium/cilium-envoy:v1.37.6-1789133542-cbec91f666af0bf742da986d43832932dbb26b82 \
    docker.io/envoyproxy/gateway:v${ENVOY_GATEWAY_VERSION#v} \
    docker.io/envoyproxy/envoy:distroless-v1.39.1 \
    prom/prometheus:v3.8.0 \
    otel/opentelemetry-collector-contrib:0.136.0 \
    postgres:17-alpine \
    mysql:8.4 \
    redis:7-alpine \
    nginx:1.27-alpine \
    hyperdx/hyperdx-all-in-one:latest \
    ghcr.io/kite-org/kite:latest; do
    import_system_image "${system_image}"
  done
fi

SERVER_IP="$("${KUBECTL[@]}" get node "k3d-${CLUSTER_NAME}-server-0" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
  --version "${CILIUM_VERSION}" --namespace kube-system --create-namespace \
  -f infra/network/cilium-values.yaml \
  --set "k8sServiceHost=${SERVER_IP}" --set k8sServicePort=6443
"${KUBECTL[@]}" -n kube-system rollout status daemonset/cilium --timeout=300s
"${KUBECTL[@]}" -n kube-system rollout status deployment/cilium-operator --timeout=300s

"${KUBECTL[@]}" apply --server-side --force-conflicts -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" --namespace envoy-gateway-system --create-namespace \
  -f infra/network/envoy-gateway-values.yaml
"${KUBECTL[@]}" -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=300s
"${KUBECTL[@]}" apply -f infra/k3s/namespace.yaml
if [[ "${HYPERDX_MODE}" == "local" ]]; then
  "${KUBECTL[@]}" apply -f infra/observability/hyperdx-secret.yaml -f infra/observability/hyperdx.yaml
  HYPERDX_OTLP_ENDPOINT="${HYPERDX_OTLP_ENDPOINT:-http://hyperdx:4318}"
  COLLECTOR_API_KEY="k3s-gofr-local-ingestion"
else
  HYPERDX_OTLP_ENDPOINT="${HYPERDX_OTLP_ENDPOINT:-https://in-otel.hyperdx.io}"
  COLLECTOR_API_KEY="${HYPERDX_API_KEY:-}"
fi
BROWSER_API_KEY="${VITE_OTEL_INGESTION_KEY:-k3s-gofr-browser-ingestion}"
printf '%s' "${BROWSER_API_KEY}" > .runtime/browser-ingestion-key
chmod 600 .runtime/browser-ingestion-key
"${KUBECTL[@]}" create secret generic hyperdx -n "${NAMESPACE}" \
  --from-literal=api-key="${COLLECTOR_API_KEY}" \
  --from-literal=browser-api-key="${BROWSER_API_KEY}" \
  --from-literal=otlp-endpoint="${HYPERDX_OTLP_ENDPOINT}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" apply -f infra/observability/config.yaml -f infra/observability/collector.yaml
"${KUBECTL[@]}" apply -f infra/observability/prometheus-rules.yaml -f infra/observability/prometheus.yaml
"${KUBECTL[@]}" apply -f infra/data/postgres.yaml -f infra/data/mysql-redis.yaml
"${KUBECTL[@]}" apply -f infra/apps/services.yaml -f infra/apps/autoscaling.yaml
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
GO_BUILD_CACHE="${GOCACHE:-${PWD}/.runtime/go-cache}"
(cd services && GOCACHE="${GO_BUILD_CACHE}" CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o ../.runtime/catalog ./catalog)
(cd services && GOCACHE="${GO_BUILD_CACHE}" CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o ../.runtime/orders ./orders)
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
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout restart deploy/otel-collector

"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/catalog --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/orders --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/web --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/otel-collector --timeout=180s
if [[ "${HYPERDX_MODE}" == "local" ]]; then
  "${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/hyperdx --timeout=360s
fi
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
  import_pod_images envoy-gateway-system
  import_pod_images gofr-demo
  "${KUBECTL[@]}" -n gofr-demo rollout restart deployment -l gateway.envoyproxy.io/owning-gateway-name=public 2>/dev/null || true
fi

GATEWAY_NAMESPACE=''
GATEWAY_SERVICE=''
until read -r GATEWAY_NAMESPACE GATEWAY_SERVICE < <("${KUBECTL[@]}" get service -A -l gateway.envoyproxy.io/owning-gateway-name=public -o jsonpath='{range .items[0]}{.metadata.namespace} {.metadata.name}{end}' 2>/dev/null); [[ -n "${GATEWAY_SERVICE}" ]]; do
  sleep 2
done
"${KUBECTL[@]}" -n gofr-demo wait gateway/public --for=condition=Programmed --timeout=180s
"${KUBECTL[@]}" -n "${NAMESPACE}" wait gateway/public --for=condition=Programmed --timeout=120s

start_forward() {
  local url="$1" namespace="$2" service="$3" mapping_string="$4" pid_file="$5" log_file="$6"
  read -r -a mappings <<< "${mapping_string}"
  # 上一次 Shell 可能留下仍在工作的端口转发和过期 PID 文件。尽可能复用存活的转发；
  # 否则只有确认进程确实是 kubectl port-forward 时才替换并写入新的 PID 文件。
  if [[ -n "${url}" ]] && curl --noproxy '*' --fail --silent --max-time 2 "${url}" >/dev/null 2>&1; then
    return
  fi
  if [[ -f "${pid_file}" ]]; then
    local previous_pid
    previous_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${previous_pid}" ]] && kill -0 "${previous_pid}" 2>/dev/null \
      && ps -p "${previous_pid}" -o args= 2>/dev/null | grep -q 'kubectl.*port-forward'; then
      if [[ -z "${url}" ]]; then
        return
      fi
      kill "${previous_pid}" 2>/dev/null || true
      sleep 0.2
    fi
    rm -f "${pid_file}"
  fi
  setsid sh -c 'exec "$@"' sh "${KUBECTL[@]}" -n "${namespace}" port-forward --address 0.0.0.0 "service/${service}" "${mappings[@]}" >"${log_file}" 2>&1 &
  echo $! >"${pid_file}"
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

start_forward http://127.0.0.1:8080/ "${GATEWAY_NAMESPACE}" "${GATEWAY_SERVICE}" 8080:80 .runtime/port-forward.pid .runtime/port-forward.log
start_forward http://127.0.0.1:18080/ kube-system kite 18080:8080 .runtime/kite-port-forward.pid .runtime/kite-port-forward.log
start_forward http://127.0.0.1:19090/-/ready "${NAMESPACE}" prometheus 19090:9090 .runtime/prometheus-port-forward.pid .runtime/prometheus-port-forward.log
echo "业务入口已就绪：http://127.0.0.1:8080/"
echo "Kite：http://127.0.0.1:18080/"
echo "Prometheus：http://127.0.0.1:19090/"

bootstrap_hyperdx_local() {
  # HyperDX 本地 volume 会保留用户。只为全新安装执行初始化，避免重复执行 `make up`
  # 覆盖运维人员已有的账号。
  local installation='' registration_status=''
  for _ in $(seq 1 30); do
    installation="$(curl --noproxy '*' --silent --show-error --max-time 3 \
      http://localhost:18081/api/installation 2>/dev/null || true)"
    [[ -n "${installation}" ]] && break
    sleep 1
  done
  if [[ "${installation}" == *'"isTeamExisting":false'* ]]; then
    registration_status="$(curl --noproxy '*' --silent --show-error --output /dev/null \
      --header 'Origin: http://localhost:18081' --request POST \
      --data-urlencode "email=${HYPERDX_DEMO_EMAIL}" \
      --data-urlencode "password=${HYPERDX_DEMO_PASSWORD}" \
      --data-urlencode "confirmPassword=${HYPERDX_DEMO_PASSWORD}" \
      --write-out '%{http_code}' http://localhost:18081/api/register/password)"
    [[ "${registration_status}" == "200" ]] || {
      echo "HyperDX 本地账号注册失败（HTTP ${registration_status}）" >&2
      return 1
    }
    echo "已为 ${HYPERDX_DEMO_EMAIL} 创建 HyperDX 本地账号"
  elif [[ "${installation}" != *'"isTeamExisting":true'* ]]; then
    echo '无法获取 HyperDX 本地安装状态' >&2
    return 1
  fi
}

if [[ "${HYPERDX_MODE}" == "local" ]]; then
  start_forward http://localhost:18081/api/health "${NAMESPACE}" hyperdx 18081:8080 .runtime/hyperdx-port-forward.pid .runtime/hyperdx-port-forward.log
  start_forward '' "${NAMESPACE}" otel-collector 14318:4318 .runtime/collector-http-port-forward.pid .runtime/collector-http-port-forward.log
  bootstrap_hyperdx_local
  echo "HyperDX：http://localhost:18081/"
  echo "浏览器 OTLP 接入：http://127.0.0.1:14318/（经 Gateway 使用时无需直接访问此端口）"
fi
