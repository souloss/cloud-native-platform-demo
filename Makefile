.DEFAULT_GOAL := help

SHELL := /usr/bin/env bash

.PHONY: help up demo-up demo-verify demo-down production-platform production-storage production-example-autoscaling observability-dashboards verify down check validate test vet build frontend-build lint load-test status resource-status network-status logs clean

help:
	@printf '%s\n' \
		'用法：make <target>' \
		'' \
		'集群：' \
		'  up              demo-up 的兼容别名（本地 k3d + 示例应用）' \
		'  demo-up         创建本地 k3d 集群并部署示例应用' \
		'  demo-verify     验收本地示例应用和三类遥测' \
		'  demo-down       停止端口转发并删除本地示例集群' \
		'  production-platform  在已有 K3s 上安装生产平台组件' \
		'  production-storage   安装 Longhorn 或检查外部 CSI' \
		'  production-example-autoscaling  显式应用 GoFr 示例应用的 KEDA 规则' \
		'  observability-dashboards  将版本化 Dashboard 应用到 OpenObserve' \
		'  verify          demo-verify 的兼容别名' \
		'  status          查看节点、工作负载、Gateway API 和 HPA 状态' \
		'  resource-status 查看节点和 Pod 的 CPU/内存使用量' \
		'  network-status  查看 Cilium CNI、Envoy Gateway 和 Gateway 状态' \
		'  logs            持续查看主要应用和 Gateway 日志' \
		'  down            demo-down 的兼容别名' \
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
	$(MAKE) demo-up

demo-up:
	./scripts/up.sh

verify:
	$(MAKE) demo-verify

demo-verify:
	./scripts/verify.sh

down:
	$(MAKE) demo-down

demo-down:
	./scripts/down.sh

production-platform:
	./scripts/production/platform.sh

production-storage:
	./scripts/production/storage.sh

production-example-autoscaling:
	./scripts/production/apply-example-autoscaling.sh

observability-dashboards:
	./scripts/observability/apply-dashboards.sh

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
	kubectl -n envoy-gateway-system get deploy,pods -o wide
	kubectl -n gofr-demo get gateway,httproute
	kubectl get service -A \
		-l gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=gofr-demo
	kubectl get gatewayclass

logs:
	kubectl -n kube-system logs ds/cilium --tail=80
	kubectl -n envoy-gateway-system logs deploy/envoy-gateway --tail=80
	kubectl -n gofr-demo logs deploy/orders --tail=40
	kubectl -n gofr-demo logs deploy/catalog --tail=40

clean:
	rm -rf .runtime/catalog .runtime/orders frontend/web/dist
