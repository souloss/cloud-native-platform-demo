.DEFAULT_GOAL := help

SHELL := /usr/bin/env bash

.PHONY: help up verify down check validate test vet build frontend-build lint load-test status resource-status network-status logs clean

help:
	@printf '%s\n' \
		'Usage: make <target>' \
		'' \
		'Cluster:' \
		'  up              Create/update the k3d cluster and deploy the demo' \
		'  verify          Run the end-to-end acceptance checks' \
		'  status          Show nodes, workloads, Gateway API and HPA status' \
		'  resource-status Show node and pod CPU/memory usage' \
		'  network-status  Show Cilium and Envoy Gateway status' \
		'  logs            Tail the main application and gateway logs' \
		'  down            Stop forwards and delete the local cluster' \
		'' \
		'Development:' \
		'  check           Run all local quality checks' \
		'  validate        Check shell scripts and Git whitespace' \
		'  test            Run Go tests for all services' \
		'  vet             Run go vet for all services' \
		'  build           Build all Go services' \
		'  frontend-build  Build the Vue frontend' \
		'  load-test       Run the HPA/load-balancing demonstration' \
		'  clean           Remove generated local build output'

up:
	./scripts/up.sh

verify:
	./scripts/verify.sh

down:
	./scripts/down.sh

check: validate test vet build frontend-build

validate:
	@set -Eeuo pipefail; \
	find scripts -type f -name '*.sh' -print0 | while IFS= read -r -d '' script; do bash -n "$$script"; done; \
	git diff --check; \
	git diff --cached --check

test:
	cd services && go test ./...

vet:
	cd services && go vet ./...

build:
	cd services && go build ./...

frontend-build:
	cd frontend/web && pnpm install --frozen-lockfile && pnpm build

lint: validate vet

load-test:
	./scripts/load-test.sh

status:
	kubectl get nodes -o wide
	kubectl get pods -A
	kubectl -n gofr-demo get gateway,httproute,hpa,pdb

resource-status:
	kubectl top nodes
	kubectl top pods -A --sort-by=memory

network-status:
	kubectl -n kube-system get pods -l k8s-app=cilium -o wide
	kubectl -n kube-system get pods -l k8s-app=cilium-envoy -o wide
	kubectl -n envoy-gateway-system get deploy,pods,svc
	kubectl get gatewayclass

logs:
	kubectl -n envoy-gateway-system logs deploy/envoy-gateway --tail=80
	kubectl -n gofr-demo logs deploy/orders --tail=40
	kubectl -n gofr-demo logs deploy/catalog --tail=40

clean:
	rm -rf .runtime/catalog .runtime/orders frontend/web/dist
