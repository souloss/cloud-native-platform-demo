#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

K3S_VERSION="${K3S_VERSION:-v1.37.2+k3s1}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.7.0}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.4}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.3}"
KURED_VERSION="${KURED_VERSION:-6.1.0}"
SYSTEM_UPGRADE_CONTROLLER_VERSION="${SYSTEM_UPGRADE_CONTROLLER_VERSION:-110.0.0}"
KEDA_VERSION="${KEDA_VERSION:-2.21.0}"
OTEL_OPERATOR_VERSION="${OTEL_OPERATOR_VERSION:-0.129.0}"
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.6.1}"
OPENOBSERVE_CHART_VERSION="${OPENOBSERVE_CHART_VERSION:-1.1.4}"
STORAGE_BACKEND="${STORAGE_BACKEND:-cloud-csi}"
STORAGE_CLASS="${STORAGE_CLASS:-fast-rwo}"
INSTALL_STORAGE="${INSTALL_STORAGE:-true}"
MIN_SERVERS="${MIN_SERVERS:-3}"
MIN_WORKERS="${MIN_WORKERS:-2}"
SKIP_NODE_TOPOLOGY_CHECK="${SKIP_NODE_TOPOLOGY_CHECK:-false}"
SKIP_K3S_VERSION_CHECK="${SKIP_K3S_VERSION_CHECK:-false}"
APPLY_ISSUERS="${APPLY_ISSUERS:-false}"
APPLY_EDGE_RESOURCES="${APPLY_EDGE_RESOURCES:-false}"
APPLY_COLLECTOR="${APPLY_COLLECTOR:-true}"
APPLY_DASHBOARDS="${APPLY_DASHBOARDS:-false}"
APPLY_HOST_JOURNALD="${APPLY_HOST_JOURNALD:-false}"
APPLY_KUBERNETES_AUDIT="${APPLY_KUBERNETES_AUDIT:-false}"
APPLY_KUBERNETES_EVENTS="${APPLY_KUBERNETES_EVENTS:-${APPLY_COLLECTOR}}"
APPLY_HUBBLE_EVENTS="${APPLY_HUBBLE_EVENTS:-false}"
REMOVE_OPTIONAL_COLLECTORS="${REMOVE_OPTIONAL_COLLECTORS:-false}"
INSTALL_CERT_MANAGER="${INSTALL_CERT_MANAGER:-true}"
INSTALL_KURED="${INSTALL_KURED:-true}"
INSTALL_SYSTEM_UPGRADE_CONTROLLER="${INSTALL_SYSTEM_UPGRADE_CONTROLLER:-true}"
INSTALL_OTEL_OPERATOR="${INSTALL_OTEL_OPERATOR:-true}"
INSTALL_OPENOBSERVE="${INSTALL_OPENOBSERVE:-true}"
INSTALL_KEDA="${INSTALL_KEDA:-true}"
INSTALL_ENVOY_GATEWAY="${INSTALL_ENVOY_GATEWAY:-true}"
ENABLE_HUBBLE="${ENABLE_HUBBLE:-true}"
ENABLE_HUBBLE_EVENTS="${ENABLE_HUBBLE_EVENTS:-${APPLY_HUBBLE_EVENTS}}"
CILIUM_K8S_SERVICE_HOST="${CILIUM_K8S_SERVICE_HOST:-}"

die() {
  echo "production platform: $*" >&2
  exit 1
}

ensure_namespace() {
  local namespace="$1" enforce="$2"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "${namespace}" \
    "pod-security.kubernetes.io/enforce=${enforce}" \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null
}

command -v kubectl >/dev/null || die "kubectl is required"
command -v helm >/dev/null || die "helm is required"

[[ "${APPLY_HUBBLE_EVENTS}" != true || "${ENABLE_HUBBLE}" == true ]] \
  || die "APPLY_HUBBLE_EVENTS=true requires ENABLE_HUBBLE=true"
[[ "${APPLY_COLLECTOR}" != true || "${INSTALL_OTEL_OPERATOR}" == true ]] \
  || die "APPLY_COLLECTOR=true requires INSTALL_OTEL_OPERATOR=true"
[[ "${APPLY_EDGE_RESOURCES}" != true || "${INSTALL_ENVOY_GATEWAY}" == true ]] \
  || die "APPLY_EDGE_RESOURCES=true requires INSTALL_ENVOY_GATEWAY=true"

[[ "${KUBECONFIG:-}" != *k3d* ]] || die "production-platform refuses a k3d kubeconfig"
kubectl cluster-info >/dev/null || die "Kubernetes API is not reachable"
context="$(kubectl config current-context 2>/dev/null || true)"
[[ "${context}" != k3d-* && "${context}" != *preview* ]] \
  || die "production-platform refuses preview context ${context}"

if [[ "${SKIP_NODE_TOPOLOGY_CHECK}" != true ]]; then
  servers="$(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  workers="$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  (( servers >= MIN_SERVERS )) || die "need at least ${MIN_SERVERS} control-plane nodes; found ${servers}"
  (( workers >= MIN_WORKERS )) || die "need at least ${MIN_WORKERS} worker nodes; found ${workers}"
fi

if [[ "${SKIP_K3S_VERSION_CHECK}" != true ]]; then
  node_versions="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u)"
  [[ "${node_versions}" == "${K3S_VERSION}" ]] \
    || die "all nodes must run ${K3S_VERSION}; found: ${node_versions//$'\n'/, }"
fi

if [[ -z "${CILIUM_K8S_SERVICE_HOST}" ]]; then
  die "set CILIUM_K8S_SERVICE_HOST to the private API LB/VIP address"
fi

[[ "${STORAGE_BACKEND}" == longhorn || "${STORAGE_BACKEND}" == cloud-csi ]] \
  || die "STORAGE_BACKEND must be longhorn or cloud-csi"

if [[ "${STORAGE_BACKEND}" == cloud-csi ]]; then
  kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1 \
    || die "StorageClass/${STORAGE_CLASS} must exist before production-platform runs"
fi

kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

cilium_args=(
  helm upgrade --install cilium oci://quay.io/cilium/charts/cilium
  --version "${CILIUM_VERSION}"
  --namespace kube-system
  --create-namespace
  -f infra/production/network/cilium-values.yaml
  --set "k8sServiceHost=${CILIUM_K8S_SERVICE_HOST}"
  --set k8sServicePort=6443
  --set "hubble.enabled=${ENABLE_HUBBLE}"
  --set "hubble.relay.enabled=${ENABLE_HUBBLE}"
  --set "hubble.export.static.enabled=${ENABLE_HUBBLE_EVENTS}"
  --set 'hubble.export.static.filePath=/var/run/cilium/hubble/events.log'
  --set hubble.export.static.fileMaxSizeMb=100
  --set hubble.export.static.fileMaxBackups=5
  --set hubble.export.static.fileCompress=true
)
helm "${cilium_args[@]:1}"
kubectl -n kube-system rollout status daemonset/cilium --timeout=600s
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=600s

if [[ "${INSTALL_ENVOY_GATEWAY}" == true ]]; then
  ensure_namespace envoy-gateway-system baseline
  helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
    --version "${ENVOY_GATEWAY_VERSION}" \
    --namespace envoy-gateway-system \
    --create-namespace \
    -f infra/production/network/envoy-gateway-values.yaml
  kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=600s
fi

if [[ "${INSTALL_OPENOBSERVE}" == true || "${APPLY_COLLECTOR}" == true ]]; then
  ensure_namespace observability baseline
fi
if [[ "${INSTALL_OPENOBSERVE}" == true ]]; then
  ensure_namespace openobserve restricted
fi
if [[ "${INSTALL_STORAGE}" == true ]]; then
  STORAGE_BACKEND="${STORAGE_BACKEND}" STORAGE_CLASS="${STORAGE_CLASS}" \
    LONGHORN_VERSION="${LONGHORN_VERSION:-1.13.0}" scripts/production/storage.sh
elif [[ "${INSTALL_OPENOBSERVE}" == true ]]; then
  kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1 \
    || die "INSTALL_STORAGE=false with INSTALL_OPENOBSERVE=true still requires StorageClass/${STORAGE_CLASS}"
fi

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add kured https://kubereboot.github.io/charts >/dev/null 2>&1 || true
helm repo add rancher https://charts.rancher.io >/dev/null 2>&1 || true
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo add openobserve https://charts.openobserve.ai >/dev/null 2>&1 || true
helm repo update jetstack kured rancher kedacore open-telemetry openobserve >/dev/null

if [[ "${INSTALL_CERT_MANAGER}" == true ]]; then
  ensure_namespace cert-manager baseline
  helm upgrade --install cert-manager jetstack/cert-manager \
    --version "${CERT_MANAGER_VERSION}" \
    --namespace cert-manager \
    --create-namespace \
    -f infra/production/platform/cert-manager-values.yaml
  kubectl -n cert-manager rollout status deployment/cert-manager --timeout=600s
  kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=600s
  kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=600s
  if [[ "${APPLY_ISSUERS}" == true ]]; then
    kubectl -n cert-manager get secret cloudflare-api-token >/dev/null \
      || die "cloudflare-api-token is required before APPLY_ISSUERS=true"
    kubectl apply -f infra/production/platform/issuers.yaml
  fi
elif [[ "${APPLY_ISSUERS}" == true ]]; then
  die "APPLY_ISSUERS=true requires INSTALL_CERT_MANAGER=true"
fi

if [[ "${INSTALL_KURED}" == true ]]; then
  ensure_namespace kured privileged
  helm upgrade --install kured kured/kured \
    --version "${KURED_VERSION}" \
    --namespace kured \
    --create-namespace \
    -f infra/production/platform/kured-values.yaml
  kubectl -n kured rollout status daemonset/kured --timeout=600s
fi

if [[ "${INSTALL_SYSTEM_UPGRADE_CONTROLLER}" == true ]]; then
  ensure_namespace system-upgrade restricted
  ensure_namespace cattle-system restricted
  helm upgrade --install system-upgrade-controller rancher/system-upgrade-controller \
    --version "${SYSTEM_UPGRADE_CONTROLLER_VERSION}" \
    --namespace system-upgrade \
    --create-namespace \
    -f infra/production/platform/system-upgrade-controller-values.yaml
  kubectl -n cattle-system rollout status deployment/system-upgrade-controller --timeout=600s
  kubectl apply -f infra/production/platform/system-upgrade-plans.yaml
fi

if [[ "${INSTALL_KEDA}" == true ]]; then
  ensure_namespace keda restricted
  helm upgrade --install keda kedacore/keda \
    --version "${KEDA_VERSION}" \
    --namespace keda \
    --create-namespace \
    -f infra/production/platform/keda-values.yaml
  kubectl -n keda rollout status deployment/keda-operator --timeout=600s
  kubectl -n keda rollout status deployment/keda-admission-webhooks --timeout=600s
fi

if [[ "${INSTALL_OPENOBSERVE}" == true ]]; then
  kubectl -n openobserve get secret openobserve-secrets >/dev/null \
    || die "create openobserve/openobserve-secrets from the external secret manager first"
  helm upgrade --install openobserve openobserve/openobserve \
    --version "${OPENOBSERVE_CHART_VERSION}" \
    --namespace openobserve \
    --create-namespace \
    -f infra/production/observability/openobserve-values.yaml
  kubectl -n openobserve rollout status statefulset/openobserve-ingester --timeout=900s 2>/dev/null || true
fi

if [[ "${INSTALL_OTEL_OPERATOR}" == true ]]; then
  ensure_namespace opentelemetry-operator-system restricted
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --version "${OTEL_OPERATOR_VERSION}" \
    --namespace opentelemetry-operator-system \
    --create-namespace \
    -f infra/production/platform/otel-operator-values.yaml
  kubectl -n opentelemetry-operator-system rollout status deployment/opentelemetry-operator --timeout=600s
fi

if [[ "${APPLY_COLLECTOR}" == true ]]; then
  [[ "${INSTALL_OTEL_OPERATOR}" == true ]] || die "APPLY_COLLECTOR=true requires INSTALL_OTEL_OPERATOR=true"
  kubectl -n observability get secret openobserve-otel >/dev/null \
    || die "create observability/openobserve-otel from the external secret manager first"
  for secret_key in endpoint authorization browser-ingestion-key; do
    secret_value="$(kubectl -n observability get secret openobserve-otel -o "jsonpath={.data.${secret_key}}" 2>/dev/null || true)"
    [[ -n "${secret_value}" ]] || die "observability/openobserve-otel must contain key ${secret_key}"
  done
  kubectl apply -f infra/production/observability/collector.yaml
  if [[ "${APPLY_HOST_JOURNALD}" == true ]]; then
    kubectl apply -f infra/production/observability/collector-journald.yaml
  fi
  if [[ "${APPLY_KUBERNETES_AUDIT}" == true ]]; then
    kubectl apply -f infra/production/observability/collector-kubernetes-audit.yaml
  fi
  if [[ "${APPLY_KUBERNETES_EVENTS}" == true ]]; then
    kubectl apply -f infra/production/observability/collector-kubernetes-events.yaml
  fi
  if [[ "${APPLY_HUBBLE_EVENTS}" == true ]]; then
    [[ "${ENABLE_HUBBLE_EVENTS}" == true ]] || die "APPLY_HUBBLE_EVENTS=true requires ENABLE_HUBBLE_EVENTS=true"
    kubectl apply -f infra/production/observability/collector-hubble-events.yaml
  fi
  if [[ "${REMOVE_OPTIONAL_COLLECTORS}" == true ]]; then
    [[ "${APPLY_HOST_JOURNALD}" == true ]] || kubectl -n observability delete opentelemetrycollector host-journald --ignore-not-found
    [[ "${APPLY_KUBERNETES_AUDIT}" == true ]] || kubectl -n observability delete opentelemetrycollector kubernetes-audit --ignore-not-found
    [[ "${APPLY_KUBERNETES_EVENTS}" == true ]] || kubectl -n observability delete opentelemetrycollector kubernetes-events --ignore-not-found
    [[ "${APPLY_KUBERNETES_EVENTS}" == true ]] || kubectl -n observability delete role,rolebinding otel-kubernetes-events-leader --ignore-not-found
    [[ "${APPLY_HUBBLE_EVENTS}" == true ]] || kubectl -n observability delete opentelemetrycollector hubble-events --ignore-not-found
  fi
elif [[ "${APPLY_HOST_JOURNALD}" == true || "${APPLY_KUBERNETES_AUDIT}" == true || "${APPLY_KUBERNETES_EVENTS}" == true || "${APPLY_HUBBLE_EVENTS}" == true ]]; then
  die "optional signal collectors require APPLY_COLLECTOR=true"
fi

if [[ "${APPLY_EDGE_RESOURCES}" == true ]]; then
  [[ "${APPLY_ISSUERS}" == true ]] || die "APPLY_EDGE_RESOURCES requires APPLY_ISSUERS=true"
  # Remove the old Cilium Gateway API objects during migration. Cilium remains
  # installed as the CNI and eBPF Service data plane only.
  kubectl delete gatewayclass cilium --ignore-not-found
  kubectl -n kube-system delete service cilium-envoy cilium-envoy-preview --ignore-not-found
  kubectl apply -f infra/production/network/gateway.yaml \
    -f infra/production/network/certificate.yaml \
    -f infra/production/network/openobserve-route.yaml
fi

if [[ "${APPLY_DASHBOARDS}" == true ]]; then
  [[ -n "${OPENOBSERVE_URL:-}" && -n "${OPENOBSERVE_EMAIL:-}" && -n "${OPENOBSERVE_PASSWORD:-}" ]] \
    || die "OPENOBSERVE_URL, OPENOBSERVE_EMAIL and OPENOBSERVE_PASSWORD are required before APPLY_DASHBOARDS=true"
  scripts/observability/apply-dashboards.sh
fi

echo "生产平台安装完成"
kubectl get nodes -o wide
kubectl get storageclass "${STORAGE_CLASS}"
kubectl get helmreleases.helm.cattle.io -A 2>/dev/null || true
kubectl get pods -A | grep -E 'cilium|envoy-gateway|cert-manager|kured|system-upgrade|keda|opentelemetry|openobserve' || true
