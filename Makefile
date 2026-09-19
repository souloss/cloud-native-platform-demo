.DEFAULT_GOAL := help

SHELL := /usr/bin/env bash

.PHONY: help up verify down check validate test vet build frontend-build lint load-test status resource-status network-status logs clean

help:
	@printf '%s\n' \
		'用法：make <target>' \
		'' \
		'集群：' \
		'  up              创建或更新 k3d 集群并部署演示' \
		'  verify          执行端到端验收检查' \
		'  status          查看节点、工作负载、Gateway API 和 HPA 状态' \
		'  resource-status 查看节点和 Pod 的 CPU/内存使用量' \
		'  network-status  查看 Cilium 和 Envoy Gateway 状态' \
		'  logs            持续查看主要应用和 Gateway 日志' \
		'  down            停止端口转发并删除本地集群' \
		'' \
		'开发：' \
		'  check           执行全部本地质量检查' \
		'  validate        检查 Shell 脚本和 Git 空白错误' \
		'  test            执行所有服务的 Go 测试' \
		'  vet             对所有服务执行 go vet' \
		'  build           构建所有 Go 服务' \
		'  frontend-build  构建 Vue 前端' \
		'  load-test       执行 HPA/负载均衡演示' \
		'  clean           删除生成的本地构建产物'

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
