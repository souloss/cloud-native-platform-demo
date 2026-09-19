# Local Runbook

## Lifecycle

```bash
make up       # create/update the k3d cluster and deploy all layers
make verify   # run the acceptance path, CRUD checks and telemetry checks
make status   # inspect workloads and Gateway API state
make down     # stop forwards and delete only the gofr-demo k3d cluster
```

`make up` defaults to `MODE=k3d` and does not install or modify a host k3s
systemd service. To use an existing host installation explicitly set
`MODE=host-k3s`; the corresponding `make down` then removes that host k3s
installation, so treat it as a destructive development option.

## Endpoints

| Surface | Local address |
| --- | --- |
| Application Gateway | <http://127.0.0.1:8080> |
| Kite | <http://127.0.0.1:18080> |
| Prometheus | <http://127.0.0.1:19090> |
| HyperDX UI/API | <http://localhost:18081> |
| HyperDX OTLP HTTP | <http://127.0.0.1:14318> |
| HyperDX OTLP gRPC | `127.0.0.1:14317` |

Use `localhost` for HyperDX UI/API because its local authentication cookie and
CORS origin are configured for that hostname.

On a fresh local HyperDX volume, `make up` creates the demo account from
`HYPERDX_DEMO_EMAIL` and `HYPERDX_DEMO_PASSWORD`. It never changes users in an
existing volume.

The project owns the k3d cluster named `gofr-demo` and the port-forwards listed
above. `make down` removes those resources only; it deliberately does not stop
unrelated Docker containers or host services. This makes cleanup safe on a
developer workstation that is running other projects.

## Acceptance matrix

`make verify` checks the following contracts:

1. Kubernetes metrics, Cilium health and Gateway API conditions.
2. Envoy proxy replicas, application/data/observability workloads and HPAs.
3. Kite and Prometheus availability.
4. Web delivery and catalog/order CRUD through the Gateway.
5. GoFr Prometheus metrics and OpenTelemetry signals in HyperDX.
6. Prometheus recording rules and the collector's own telemetry endpoint.

Useful PromQL after `make verify`:

```promql
gofr:http_responses:rate5m
gofr:http_response_duration_seconds:p95
sum by (operation, result) (rate(catalog_cache_operations_total[5m]))
```

The script creates temporary verification port-forwards and removes them on
exit. The persistent forwards created by `make up` remain until `make down`.

## Troubleshooting

- Check `kubectl get pods -A` and `kubectl -n gofr-demo get events --sort-by=.lastTimestamp` first.
- Inspect `make logs` for Envoy Gateway, orders and catalog.
- Run `make network-status` to separate Cilium issues from Gateway issues.
- If a previous run was interrupted, run `make down` once, confirm the ports are
  free, then run `make up` again.
- Set `PROXY_URL` when image/chart downloads must use a local proxy. Set
  `NODE_PROXY_URL` only when that proxy is reachable from Docker containers.
