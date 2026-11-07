#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

STORAGE_BACKEND="${STORAGE_BACKEND:-cloud-csi}"
STORAGE_CLASS="${STORAGE_CLASS:-fast-rwo}"
LONGHORN_VERSION="${LONGHORN_VERSION:-1.13.0}"

die() {
  echo "production storage: $*" >&2
  exit 1
}

command -v kubectl >/dev/null || die "kubectl is required"
context="$(kubectl config current-context 2>/dev/null || true)"
[[ "${context}" != k3d-* && "${context}" != *preview* ]] \
  || die "production-storage refuses preview context ${context}"

case "${STORAGE_BACKEND}" in
  longhorn)
    command -v helm >/dev/null || die "helm is required for STORAGE_BACKEND=longhorn"
    kubectl apply -f infra/production/storage/namespace.yaml
    helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
    helm repo update longhorn >/dev/null
    helm upgrade --install longhorn longhorn/longhorn \
      --version "${LONGHORN_VERSION}" \
      --namespace longhorn-system \
      --create-namespace \
      -f infra/production/storage/longhorn-values.yaml
    kubectl apply -f infra/production/storage/longhorn-storageclass.yaml
    kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s
    kubectl -n longhorn-system rollout status deployment/longhorn-driver-deployer --timeout=600s
    kubectl -n longhorn-system rollout status deployment/longhorn-ui --timeout=600s
    ;;
  cloud-csi)
    kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1 \
      || die "StorageClass/${STORAGE_CLASS} was not found; install the cloud CSI driver first"
    provisioner="$(kubectl get storageclass "${STORAGE_CLASS}" -o jsonpath='{.provisioner}')"
    [[ "${provisioner}" != driver.longhorn.io ]] \
      || die "StorageClass/${STORAGE_CLASS} points to Longhorn but STORAGE_BACKEND=cloud-csi"
    ;;
  *)
    die "STORAGE_BACKEND must be longhorn or cloud-csi"
    ;;
esac

kubectl get storageclass "${STORAGE_CLASS}" \
  -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,BINDING:.volumeBindingMode,RECLAIM:.reclaimPolicy
