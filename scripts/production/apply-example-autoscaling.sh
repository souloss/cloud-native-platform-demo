#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

die() {
  echo "production example autoscaling: $*" >&2
  exit 1
}

command -v kubectl >/dev/null || die "kubectl is required"
kubectl cluster-info >/dev/null || die "Kubernetes API is not reachable"
context="$(kubectl config current-context 2>/dev/null || true)"
[[ "${context}" != k3d-* && "${context}" != *preview* ]] \
  || die "production example autoscaling refuses preview context ${context}"
kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1 \
  || die "KEDA ScaledObject CRD is not installed"
kubectl -n gofr-demo get deployment orders >/dev/null 2>&1 \
  || die "the example gofr-demo/orders Deployment must exist first"
kubectl -n gofr-demo get secret openobserve-keda >/dev/null 2>&1 \
  || die "create gofr-demo/openobserve-keda from the external secret manager first"

kubectl apply -f infra/production/autoscaling/keda-openobserve.example.yaml
