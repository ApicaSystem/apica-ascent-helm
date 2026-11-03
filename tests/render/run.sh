#!/usr/bin/env bash
# Render tests for the apica-ascent chart: helm lint, renders with the default,
# sizing and large-fleet fixture values, and the render-time guards.
# Usage: tests/render/run.sh   (from anywhere; needs helm 3.8+)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
chart="$root/apica-ascent"
base="$root/tests/render/base-values.yaml"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
failures=0

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

render() { # render <name> [helm args...]
  local name="$1"; shift
  helm template t "$chart" -n ns -f "$base" "$@" > "$out/$name.yaml" 2> "$out/$name.err"
}

expect() { # expect <file> <description> <grep -E pattern> [count]
  local n
  n=$(grep -cE -- "$3" "$out/$1.yaml")
  if [[ -n "${4:-}" ]]; then
    [[ "$n" == "$4" ]] && pass "$2" || fail "$2 (expected $4 matches of '$3', got $n)"
  else
    [[ "$n" -gt 0 ]] && pass "$2" || fail "$2 (no match for '$3')"
  fi
}

expect_render_error() { # expect_render_error <description> <error pattern> [helm args...]
  local desc="$1" pattern="$2"; shift 2
  if helm template t "$chart" -n ns -f "$base" "$@" > /dev/null 2> "$out/err"; then
    fail "$desc (render succeeded)"
  elif grep -qE -- "$pattern" "$out/err"; then
    pass "$desc"
  else
    fail "$desc (unexpected error: $(head -1 "$out/err"))"
  fi
}

echo "== helm lint"
helm lint "$chart" -f "$base" > "$out/lint" 2>&1 && pass "helm lint" || { fail "helm lint"; cat "$out/lint"; }

echo "== default values"
if render default; then
  pass "renders"
  expect default "S2S container ports" "containerPort: 999[67]$" 2
  expect default "S2S ports on both flash Services" "^      name: s2s(tls)?$" 4
  expect default "S2S Gateway listeners" "^  - name: tcp-999[67]$" 2
  expect default "S2S TCPRoutes" "sectionName: tcp-999[67]$" 2
  expect default "podManagementPolicy defaults to OrderedReady" "podManagementPolicy: OrderedReady"
  expect default "ServiceMonitor interval defaults to 2m" "^    interval: 2m$" 6
  expect default "trace ingestion stays off" "sectionName: tcp-14250" 0
else
  fail "default render: $(head -1 "$out/default.err")"
fi

for size in small medium large single; do
  render "size-$size" -f "$chart/values.$size.yaml" && pass "values.$size.yaml renders" \
    || fail "values.$size.yaml: $(head -1 "$out/size-$size.err")"
done

echo "== large-fleet fixture (tests/render/s2s-large-values.yaml)"
if render large -f "$root/tests/render/s2s-large-values.yaml"; then
  pass "renders"
  expect large "40 flash replicas" "^  replicas: 40$"
  expect large "-workers from workersPerCPU x CPU request" "-workers 600 "
  expect large "ingest memory limit" "memory: 12Gi"
  expect large "rate limit flag" "-max_bytes_per_sec=2000000"
  expect large "ingest extraArgs on the ingest container" "-test_ingest_flag=1" 1
  expect large "query extraArgs on the query sidecar" "-sidecar-node .*-test_query_flag=1" 1
  expect large "ml extraArgs on flash-ml" "-ml-use-sidecar .*-test_ml_flag=1" 1
  expect large "sync extraArgs on flash-sync" "-sync-node -test_sync_flag=1" 1
  expect large "podManagementPolicy Parallel" "podManagementPolicy: Parallel" 1
  expect large "S2S Gateway listeners" "^  - name: tcp-999[67]$" 2
  expect large "S2S TCPRoutes" "sectionName: tcp-999[67]$" 2
  expect large "max_connections" "max_connections: \"1000\""
  expect large "LB flex-max annotation" "oci-load-balancer-shape-flex-max: \"1000\""
  expect large "ServiceMonitor interval 30s" "^    interval: 30s$" 6
  expect large "ServiceMonitor scrapeTimeout 25s" "^    scrapeTimeout: 25s$" 6
  awk '/perfectscale-flash-automation.yaml/{f=1;next} /^# Source:/{f=0} f' "$out/large.yaml" > "$out/large-ps.yaml"
  expect large-ps "PerfectScale off for flash" "automationMode: \"Disabled\"" 1
else
  fail "large-fleet render: $(head -1 "$out/large.err")"
fi

echo "== opt-outs"
if render s2s-off --set envoyGateway.s2sIngestion.enabled=false; then
  expect s2s-off "no S2S listeners when s2sIngestion is off" "^  - name: tcp-999[67]$" 0
  expect s2s-off "flash S2S ports stay on" "containerPort: 999[67]$" 2
else
  fail "s2s-off render: $(head -1 "$out/s2s-off.err")"
fi

echo "== guards"
expect_render_error "S2S listener restated in listeners.tcp" 'listener name "tcp-9996" is defined twice' \
  --set 'envoyGateway.listeners.tcp[0].name=tcp-9996,envoyGateway.listeners.tcp[0].port=9996'
expect_render_error "duplicate listener port" "port 9997 is used twice" \
  --set 'envoyGateway.listeners.tcp[0].name=other,envoyGateway.listeners.tcp[0].port=9997'
expect_render_error "too few Postgres connections" "Postgres connections: 40 logiq-flash pods" \
  --set logiq-flash.replicaCount=40
expect_render_error "scrapeTimeout longer than interval" "must not be longer than" \
  --set logiq-flash.metrics.serviceMonitor.scrapeTimeout=3m
expect_render_error "invalid duration" "not a valid Prometheus duration" \
  --set logiq-flash.metrics.serviceMonitor.interval=soon
helm template t "$chart" -n ns -f "$base" --set logiq-flash.replicaCount=40 \
  --set validation.postgresConnections.enabled=false > /dev/null 2>&1 \
  && pass "Postgres check can be turned off" || fail "Postgres check can be turned off"

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
