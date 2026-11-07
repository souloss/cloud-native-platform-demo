#!/usr/bin/env bash
set -Eeuo pipefail

K3S_VERSION="${K3S_VERSION:-v1.37.2+k3s1}"
K3S_CONFIG_FILE="${K3S_CONFIG_FILE:-}"
K3S_INSTALLER_URL="${K3S_INSTALLER_URL:-https://get.k3s.io}"
ENABLE_KUBERNETES_AUDIT="${ENABLE_KUBERNETES_AUDIT:-false}"
K3S_AUDIT_POLICY_FILE="${K3S_AUDIT_POLICY_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/infra/production/k3s/audit-policy.yaml}"
ROLE="${1:-${K3S_ROLE:-}}"

die() {
  echo "k3s node installer: $*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die "run this script as root"
command -v curl >/dev/null || die "curl is required"
[[ -n "${K3S_CONFIG_FILE}" && -f "${K3S_CONFIG_FILE}" ]] \
  || die "set K3S_CONFIG_FILE to a rendered, root-owned config file"

case "${ROLE}" in
  server-init|server-join|agent) ;;
  *) die "role must be server-init, server-join or agent" ;;
esac

if [[ "${ENABLE_KUBERNETES_AUDIT}" == true && "${ROLE}" != agent ]]; then
  [[ -f "${K3S_AUDIT_POLICY_FILE}" ]] || die "audit policy file not found: ${K3S_AUDIT_POLICY_FILE}"
  grep -Eq '^[[:space:]]*-[[:space:]]+audit-policy-file=' "${K3S_CONFIG_FILE}" \
    || die "server config must contain an uncommented audit-policy-file kube-apiserver argument"
  install -d -m 0700 /etc/rancher/k3s /var/log/kubernetes/audit
  install -o root -g root -m 0600 "${K3S_AUDIT_POLICY_FILE}" /etc/rancher/k3s/audit-policy.yaml
fi

if command -v k3s >/dev/null 2>&1; then
  installed="$(k3s --version | awk 'NR == 1 {print $3}')"
  [[ "${installed}" == "${K3S_VERSION}" ]] \
    || die "k3s ${installed} is already installed; upgrade it through System Upgrade Controller"
  echo "K3s ${installed} is already installed; nothing to do"
  exit 0
fi

install -d -m 0700 /etc/rancher/k3s
install -o root -g root -m 0600 "${K3S_CONFIG_FILE}" /etc/rancher/k3s/config.yaml

case "${ROLE}" in
  server-init|server-join)
    curl -fsSL "${K3S_INSTALLER_URL}" | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server
    ;;
  agent)
    curl -fsSL "${K3S_INSTALLER_URL}" | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - agent
    ;;
esac

systemctl enable --now k3s 2>/dev/null || systemctl enable --now k3s-agent
echo "K3s ${K3S_VERSION} ${ROLE} installation completed"
