# Cloud Native Platform Demo

Cloud Native Platform Demo is a deliberately small, production-shaped platform
reference project. It keeps the service boundary, traffic policy, telemetry
pipeline, data stores and operator workflow visible in one local k3d cluster.

## Layer model

| Layer | Responsibility | Repository location |
| --- | --- | --- |
| Edge | Gateway API contract, Envoy proxy, path routing | `infra/network` |
| Runtime | k3s, Cilium CNI, network policy and Hubble flow visibility | `infra/k3s`, `infra/network` |
| Workloads | GoFr `orders` and `catalog` APIs plus the Vue web client | `services`, `frontend/web`, `infra/apps` |
| Data | PostgreSQL, MySQL and Redis backing services | `infra/data` |
| Observability | OpenTelemetry Collector, Prometheus and HyperDX v2 | `infra/observability` |
| Operations | Kite dashboard, repeatable lifecycle and acceptance checks | `infra/dashboard`, `scripts`, `Makefile` |

The boundary is intentional: application code does not contain Kubernetes
objects, infrastructure does not contain application build logic, and the
scripts are the only layer that assembles a local environment.

## Request and signal paths

```text
Browser (Vue + HyperDX replay)
  -> Envoy Gateway / Gateway API
    -> web (static UI)
    -> orders -> PostgreSQL
              -> catalog -> MySQL
                        -> Redis cache

GoFr traces/logs/metrics -> OpenTelemetry Collector -> HyperDX v2
Pod metrics -> Prometheus
Pod network flows -> Cilium/Hubble
Cluster resources/events -> Kite
```

The `orders` service propagates W3C trace context when it calls `catalog`, so
one order request is useful as an end-to-end tracing example rather than a set
of disconnected health checks. GoFr also emits structured request logs and
Prometheus metrics; the application handlers add business spans and cache
hit/miss events so the same request can be investigated from three signal
types.

## Production-shaped choices

- Gateway API is the public contract; the Envoy proxy Service stays `ClusterIP`
  and is exposed locally only with `kubectl port-forward`.
- Workloads have more than one replica, resource requests/limits, readiness and
  liveness probes, PodDisruptionBudgets and CPU-based HPAs.
- Stateless workloads use rolling updates and hostname-based topology spreading;
  probes distinguish startup, readiness and liveness so a slow dependency does
  not receive traffic before the process is ready.
- Prometheus keeps a local TSDB PVC and recording rules for the main GoFr
  request-rate and latency signals. This is still intentionally small, but it
  gives operators a stable query surface instead of relying on raw metric names.
- Application secrets are injected through Kubernetes Secrets. The checked-in
  values are local teaching defaults only.
- Cilium replaces the default k3s networking components while kube-proxy stays
  enabled for the portable k3d profile. A kube-proxy-free profile is a separate
  cluster design, not a runtime toggle.
- The local observability stack is self-contained. Cloud HyperDX can be used by
  setting `HYPERDX_MODE=cloud` and supplying the endpoint and API key at launch.

## Deliberate local concessions

The cluster uses one server and two agents, single-replica stateful stores, a
local-path-backed PVC and `:dev` application images imported into k3d. These
choices keep the demo reproducible on a workstation; a production deployment
should pin every image by release or digest, use managed data services or a
tested storage class, externalize secrets, and define backup/restore and SLO
policies.
