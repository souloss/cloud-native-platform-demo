#!/usr/bin/env bash
set -Eeuo pipefail
target="${1:-http://127.0.0.1:8080/api/orders}"
command -v hey >/dev/null || { echo '运行负载演示前请安装 hey：go install github.com/rakyll/hey@latest' >&2; exit 1; }
hey -z 90s -c 40 "${target}"
