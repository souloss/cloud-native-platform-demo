# Production boundary

This directory contains platform and production integration contracts. It does
not contain the demo application's PostgreSQL, MySQL, Redis, Nginx, Kite or
standalone Prometheus Server manifests. Prometheus-format exporters remain part
of the Cilium, GoFr and OTel integrations.

- `k3s/`: per-node K3s configuration templates; install them over SSH.
- `network/`: production Cilium CNI, Envoy Gateway, Gateway API, TLS and OpenObserve routes.
- `platform/`: cert-manager, Kured, System Upgrade Controller, KEDA and OTel
  Operator values, cluster-scoped resources and feature flags.
- `observability/`: production OpenObserve values, external Secret contracts
  and OTel Collector resources.
- `storage/`: optional Longhorn adapter and the `fast-rwo` StorageClass
  contract. A cloud CSI driver can provide the same StorageClass instead.
- `autoscaling/`: workload-specific examples. The platform installer does not
  apply them automatically because the target Deployment belongs to the
  application owner. The GoFr/OpenObserve example can be applied explicitly
  with `make production-example-autoscaling` after its Deployment and Secret
  exist.

Use `scripts/production/platform.sh` after the K3s cluster exists. Use
`scripts/production/storage.sh` exactly once with either
`STORAGE_BACKEND=longhorn` or `STORAGE_BACKEND=cloud-csi`.

The platform installer exposes `INSTALL_*`, `ENABLE_HUBBLE` and `APPLY_*` switches for
non-essential controllers and signal collectors. The baseline Collector handles node,
kubelet, Kubernetes-object and container signals. Opt into `APPLY_HOST_JOURNALD`,
`APPLY_KUBERNETES_AUDIT` and `APPLY_HUBBLE_EVENTS` when the corresponding host access,
K3s audit configuration and network-flow volume are acceptable.
`platform/feature-flags.example.env` is the non-secret starting point for these choices.
