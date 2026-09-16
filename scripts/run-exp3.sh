#!/usr/bin/env bash
#
# run-exp3.sh — inject 500ms of Redis latency and watch the SLIs diverge.
#
# The point of this experiment is the contrast: availability should hold,
# every probe should stay green, and the latency objective should collapse.
# So each sample records both SLIs side by side, plus pod readiness, from
# Prometheus rather than from a hand-run probe.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ns=helios-prod

kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null' EXIT
sleep 5

q() {
  curl -sS --max-time 10 --get 'http://localhost:19090/api/v1/query' \
    --data-urlencode "query=$1" 2>/dev/null \
  | python -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(f\"{float(r[0]['value'][1]):.3f}\" if r else '-')" 2>/dev/null
}

not_ready() {
  kubectl -n "$ns" get pods --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); if (a[1]!=a[2]) n++} END {print n+0}'
}

sample() {
  local el="$1"
  printf '  t+%4ss  latency_good_5m=%-6s  error_ratio_5m=%-6s  submit_p95_s=%-6s  pods_not_ready=%s\n' \
    "$el" \
    "$(q 'job:slo_latency_good:ratio_rate5m')" \
    "$(q 'job:slo_errors:ratio_rate5m')" \
    "$(q 'histogram_quantile(0.95, sum by (le) (rate(orion_http_request_duration_seconds_bucket{namespace="helios-prod",route="/submit"}[2m])))')" \
    "$(not_ready)"
}

echo "before injection:"
sample 0

t0=$(date +%s)
echo
echo "injecting 500ms Redis latency at $(date -u +%H:%M:%S)Z (duration 5m)"
kubectl apply -f "$here/chaos/03-redis-latency.yaml" >/dev/null

# Sample for the 5 minutes of injection plus 3 minutes of recovery.
while :; do
  el=$(( $(date +%s) - t0 ))
  [ "$el" -gt 480 ] && break
  sample "$el"
  sleep 30
done

echo
echo "chaos status:"
kubectl -n "$ns" get networkchaos redis-latency \
  -o jsonpath='  phase={.status.experiment.desiredPhase}{"\n"}' 2>/dev/null

echo
echo "alert state for the latency objective:"
curl -sS --max-time 10 --get 'http://localhost:19090/api/v1/query' \
  --data-urlencode 'query=ALERTS{alertname="OrionDispatchLatencyObjectiveAtRisk"}' \
  | python -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print('  ', [x['metric'].get('alertstate') for x in r] or 'not active')"
