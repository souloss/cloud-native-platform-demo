# Production storage backends

The production OpenObserve values deliberately refer to a stable interface:
`StorageClass/fast-rwo`. Choose exactly one backend before installing
OpenObserve.

## Longhorn

Use this option when the nodes have dedicated persistent disks and the cluster
should provide replicated block volumes itself:

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update longhorn
kubectl apply -f infra/production/storage/namespace.yaml
helm upgrade --install longhorn longhorn/longhorn \
  --version 1.13.0 \
  --namespace longhorn-system \
  --create-namespace \
  -f infra/production/storage/longhorn-values.yaml
kubectl apply -f infra/production/storage/longhorn-storageclass.yaml
kubectl -n longhorn-system rollout status deployment/longhorn-ui --timeout=300s
kubectl get storageclass fast-rwo
```

Longhorn requires the supported iSCSI/NFS host prerequisites and a disk path
with sufficient capacity on every storage node. The default replica count is
three; do not deploy it on fewer than three suitable storage nodes.

## Cloud CSI

Install the cloud provider's CSI driver and create a `fast-rwo` StorageClass
with equivalent guarantees: expansion, `WaitForFirstConsumer`, snapshots and
the required reclaim policy. Do not install Longhorn or apply its
StorageClass. The OpenObserve chart and NATS PVCs then use the provider CSI
through the same `fast-rwo` name.

`fast-rwo` is intentionally not marked as the cluster default. Every
production PVC must name it explicitly so unrelated workloads cannot consume
the observability storage backend accidentally.
