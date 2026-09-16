#!/usr/bin/env bash
#
# sample.sh — record what the autoscalers actually did during a load test.
#
#   ./scripts/loadtest/sample.sh results/scale.csv 600
#
# One row every 10 seconds: queue depth, worker replicas (desired and ready),
# API replicas, node count, and pending pods. The autoscaling claim rests on
# this file, not on watching `kubectl get pods -w` and remembering what
# happened.

set -uo pipefail

out="${1:-results/scale.csv}"
seconds="${2:-600}"
ns="helios-prod"

mkdir -p "$(dirname "$out")"
echo "elapsed_s,queue_depth,worker_desired,worker_ready,api_ready,nodes,nodes_ready,pending_pods" > "$out"

start=$(date +%s)
while :; do
  now=$(date +%s)
  elapsed=$((now - start))
  [ "$elapsed" -gt "$seconds" ] && break

  depth=$(kubectl -n "$ns" get --raw \
    "/api/v1/namespaces/${ns}/services/orion-api:80/proxy/stats" 2>/dev/null \
    | sed -n 's/.*"queue_size"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')

  wdesired=$(kubectl -n "$ns" get deploy orion-worker -o jsonpath='{.spec.replicas}' 2>/dev/null)
  wready=$(kubectl -n "$ns" get deploy orion-worker -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  aready=$(kubectl -n "$ns" get deploy orion-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  nready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  pending=$(kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')

  echo "${elapsed},${depth:-},${wdesired:-0},${wready:-0},${aready:-0},${nodes},${nready},${pending}" >> "$out"
  sleep 10
done

echo "wrote $(($(wc -l < "$out") - 1)) samples to $out"
