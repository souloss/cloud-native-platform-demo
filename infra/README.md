# Infrastructure boundaries

The top-level `infra/apps`, `infra/data`, `infra/network`,
`infra/observability`, `infra/dashboard` and `infra/k3s` manifests are the
local k3d demo overlay used by `make demo-up`. They intentionally include the
sample application's PostgreSQL, MySQL, Redis, Prometheus, Kite and Nginx
runtime dependencies.

They are kept at their existing paths for compatibility with the demo scripts.
Production resources live under `infra/production` and are installed only by
`scripts/production/platform.sh` and `scripts/production/storage.sh`.
