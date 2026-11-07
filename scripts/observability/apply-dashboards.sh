#!/usr/bin/env bash
set -Eeuo pipefail

# Apply the versioned OpenObserve dashboards without embedding credentials in Git.
# Set OPENOBSERVE_URL, OPENOBSERVE_EMAIL and OPENOBSERVE_PASSWORD through the
# external secret manager or the deployment environment before running this.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENOBSERVE_URL="${OPENOBSERVE_URL:?set OPENOBSERVE_URL, for example https://observe.example.com}"
OPENOBSERVE_ORG="${OPENOBSERVE_ORG:-default}"
OPENOBSERVE_FOLDER="${OPENOBSERVE_FOLDER:-default}"
OPENOBSERVE_EMAIL="${OPENOBSERVE_EMAIL:?set OPENOBSERVE_EMAIL}"
OPENOBSERVE_PASSWORD="${OPENOBSERVE_PASSWORD:?set OPENOBSERVE_PASSWORD}"
OBSERVABILITY_DASHBOARDS_PROFILE="${OBSERVABILITY_DASHBOARDS_PROFILE:-core}"
OBSERVABILITY_DASHBOARDS_PRUNE="${OBSERVABILITY_DASHBOARDS_PRUNE:-true}"
OBSERVABILITY_DEMO_APP_ENABLED="${OBSERVABILITY_DEMO_APP_ENABLED:-false}"
API="${OPENOBSERVE_URL%/}/api/${OPENOBSERVE_ORG}"
AUTH=(-u "${OPENOBSERVE_EMAIL}:${OPENOBSERVE_PASSWORD}")

case "${OBSERVABILITY_DASHBOARDS_PROFILE}" in
  core)
    dashboard_files=(
      "${ROOT_DIR}/infra/observability/dashboards/k3s-cluster-overview.json"
      "${ROOT_DIR}/infra/observability/dashboards/k3s-observability-pipeline.json"
    )
    ;;
  demo)
    dashboard_files=(
      "${ROOT_DIR}/infra/observability/dashboards/k3s-cluster-overview.json"
      "${ROOT_DIR}/infra/observability/dashboards/k3s-observability-pipeline.json"
      "${ROOT_DIR}/infra/observability/dashboards/k3s-workloads-autoscaling.json"
    )
    ;;
  *)
    echo "unsupported OBSERVABILITY_DASHBOARDS_PROFILE=${OBSERVABILITY_DASHBOARDS_PROFILE}; use core or demo" >&2
    exit 2
    ;;
esac
managed_dashboard_titles=("K3s Cluster Overview" "K3s Observability Pipeline" "K3s Workloads & Autoscaling")
applied_dashboard_titles=()

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# OpenObserve creates streams lazily. Filter panels against the current stream
# inventory so an optional signal source does not produce an empty/broken panel.
metrics_streams="$(curl --fail-with-body --silent --show-error "${AUTH[@]}" \
  "${API}/streams?type=metrics" | jq -c '[.list[]?.name]')"
logs_streams="$(curl --fail-with-body --silent --show-error "${AUTH[@]}" \
  "${API}/streams?type=logs" | jq -c '[.list[]?.name]')"
traces_streams="$(curl --fail-with-body --silent --show-error "${AUTH[@]}" \
  "${API}/streams?type=traces" | jq -c '[.list[]?.name]')"

has_stream() {
  local stream_type="$1" stream_name="$2"
  case "${stream_type}" in
    metrics) jq -e --arg name "${stream_name}" 'any(.[]; . == $name)' <<<"${metrics_streams}" >/dev/null ;;
    logs) jq -e --arg name "${stream_name}" 'any(.[]; . == $name)' <<<"${logs_streams}" >/dev/null ;;
    traces) jq -e --arg name "${stream_name}" 'any(.[]; . == $name)' <<<"${traces_streams}" >/dev/null ;;
    *) return 1 ;;
  esac
}

for file in "${dashboard_files[@]}"; do
  title="$(jq -r '.title' "${file}")"
  filtered_file="${tmp_dir}/$(basename "${file}")"
  jq --argjson metrics "${metrics_streams}" \
    --argjson logs "${logs_streams}" \
    --argjson traces "${traces_streams}" '
      def stream_exists:
        .queries[0].fields as $field |
        if $field.stream_type == "metrics" then
          ($metrics | any(.[]; . == $field.stream))
        elif $field.stream_type == "logs" then
          ($logs | any(.[]; . == $field.stream))
        elif $field.stream_type == "traces" then
          ($traces | any(.[]; . == $field.stream))
        else false end;
      .tabs |= map(.panels |= map(select(stream_exists)))
    ' "${file}" >"${filtered_file}"

  panel_count="$(jq '[.tabs[]?.panels[]?] | length' "${filtered_file}")"
  if [[ "${panel_count}" == 0 ]]; then
    echo "skipped ${title}: no matching OpenObserve streams (profile=${OBSERVABILITY_DASHBOARDS_PROFILE})"
    continue
  fi

  # The workload dashboard belongs to the optional GoFr sample, not the core
  # platform. Require an explicit opt-in as well as its metric stream.
  if [[ "${title}" == "K3s Workloads & Autoscaling" ]]; then
    if [[ "${OBSERVABILITY_DEMO_APP_ENABLED}" != true ]]; then
      echo "skipped ${title}: set OBSERVABILITY_DEMO_APP_ENABLED=true only when the sample app is deployed"
      continue
    fi
    if ! has_stream metrics app_http_response_count; then
      echo "skipped ${title}: example application metrics are absent"
      continue
    fi
  fi

  existing="$(curl --fail-with-body --silent --show-error "${AUTH[@]}" \
    "${API}/dashboards?folder=${OPENOBSERVE_FOLDER}" \
    | jq -c --arg title "${title}" '.dashboards[]? | select(.title == $title) | {id: .dashboard_id, hash: .hash}' \
    | head -n 1)"

  if [[ -n "${existing}" ]]; then
    dashboard_id="$(jq -r '.id' <<<"${existing}")"
    dashboard_hash="$(jq -r '.hash' <<<"${existing}")"
    curl --fail-with-body --silent --show-error "${AUTH[@]}" \
      -H 'content-type: application/json' -X PUT \
      "${API}/dashboards/${dashboard_id}?folder=${OPENOBSERVE_FOLDER}&hash=${dashboard_hash}" \
      --data-binary "@${filtered_file}" >/dev/null
    echo "updated ${title} (${dashboard_id})"
  else
    response="$(curl --fail-with-body --silent --show-error "${AUTH[@]}" \
      -H 'content-type: application/json' -X POST \
      "${API}/dashboards?folder=${OPENOBSERVE_FOLDER}" \
      --data-binary "@${filtered_file}")"
    dashboard_id="$(jq -r '.v8.dashboardId // .dashboard_id // empty' <<<"${response}")"
    [[ -n "${dashboard_id}" ]] || { echo "OpenObserve did not return a dashboard id for ${title}" >&2; exit 1; }
    echo "created ${title} (${dashboard_id})"
  fi
  applied_dashboard_titles+=("${title}")
done

if [[ "${OBSERVABILITY_DASHBOARDS_PRUNE}" == true ]]; then
  managed_json="$(printf '%s\n' "${managed_dashboard_titles[@]}" | jq -R . | jq -s .)"
  applied_json="$(printf '%s\n' "${applied_dashboard_titles[@]:-}" | jq -R . | jq -s .)"
  existing_dashboards="$(curl --fail-with-body --silent --show-error "${AUTH[@]}" \
    "${API}/dashboards?folder=${OPENOBSERVE_FOLDER}")"
  jq -r --argjson managed "${managed_json}" --argjson applied "${applied_json}" \
    '.dashboards[]? | select(.title as $title | ($managed | index($title)) != null and ($applied | index($title)) == null) | [.dashboard_id, .title] | @tsv' \
    <<<"${existing_dashboards}" \
    | while IFS=$'\t' read -r dashboard_id dashboard_title; do
        [[ -n "${dashboard_id}" ]] || continue
        curl --fail-with-body --silent --show-error "${AUTH[@]}" -X DELETE \
          "${API}/dashboards/${dashboard_id}?folder=${OPENOBSERVE_FOLDER}" >/dev/null
        echo "deleted ${dashboard_title} (${dashboard_id}): outside the active profile or missing source streams"
      done
fi
