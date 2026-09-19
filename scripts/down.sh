#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SUDO=(); [[ ${EUID} -ne 0 ]] && SUDO=(sudo)
K=("${SUDO[@]}" k3s kubectl)

stop_forward() {
  local pidfile="$1" pid=''
  [[ -f "${pidfile}" ]] || return 0
  pid="$(<"${pidfile}")"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && (( pid > 1 )) && kill -0 "${pid}" 2>/dev/null \
    && ps -p "${pid}" -o args= 2>/dev/null | grep -q '[k]ubectl.*port-forward'; then
    # up.sh 会在独立会话中启动端口转发。停止整个进程组，避免删除演示集群后
    # kubectl 子进程仍然存活。
    kill -- "-${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "${pid}" 2>/dev/null; then
      kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
    fi
  fi
  rm -f "${pidfile}"
}

for pidfile in \
  .runtime/port-forward.pid \
  .runtime/kite-port-forward.pid \
  .runtime/prometheus-port-forward.pid \
  .runtime/hyperdx-port-forward.pid \
  .runtime/hyperdx-grpc-port-forward.pid; do
  stop_forward "${pidfile}"
done

if [[ "${MODE:-k3d}" == "k3d" ]] && command -v k3d >/dev/null; then
  cluster_name="${K3D_CLUSTER_NAME:-gofr-demo}"
  if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -Fxq "${cluster_name}"; then
    k3d cluster delete "${cluster_name}"
  else
    echo "k3d 集群 ${cluster_name} 已停止"
  fi
  exit 0
fi
"${K[@]}" delete namespace gofr-demo --ignore-not-found
"${K[@]}" delete gatewayclass envoy-gateway --ignore-not-found
"${K[@]}" delete namespace envoy-gateway-system --ignore-not-found
if command -v helm >/dev/null; then
  helm uninstall envoy-gateway -n envoy-gateway-system --ignore-not-found 2>/dev/null || true
  helm uninstall cilium -n kube-system --ignore-not-found 2>/dev/null || true
fi
if command -v k3s-uninstall.sh >/dev/null; then "${SUDO[@]}" k3s-uninstall.sh; fi
