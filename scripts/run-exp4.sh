#!/usr/bin/env bash
#
# run-exp4.sh — drain one node and measure what the other can absorb.
#
# Drains the node running FEWER helios-prod pods, so the experiment asks
# whether the survivor can take the rest. Records evictions, rescheduling,
# anything left Pending, and whether a real job round-trips throughout.
#
# Always uncordons at the end, even on failure: a cordoned node on a two-node
# cluster at its vCPU cap is half the cluster gone until someone notices.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
api="${API:-http://localhost:18080}"
ns=helios-prod

# Pick the node with fewer application pods.
node=$(kubectl -n "$ns" get pods -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
       | sort | uniq -c | sort -n | head -1 | awk '{print $2}')
[ -z "$node" ] && { echo "could not pick a node"; exit 1; }

trap 'echo; echo "uncordoning $node"; kubectl uncordon "$node" >/dev/null 2>&1' EXIT

echo "draining: $node"
echo "application pods on it:"
kubectl -n "$ns" get pods -o wide --field-selector spec.nodeName="$node" --no-headers \
  | awk '{print "  " $1}'
echo

t0=$(date +%s)
kubectl cordon "$node" >/dev/null
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
  --timeout=180s --grace-period=30 > "${here}/docs/gamedays/exp4-drain.log" 2>&1 &
drain_pid=$!

while kill -0 "$drain_pid" 2>/dev/null; do
  el=$(( $(date +%s) - t0 ))
  pending=$(kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
  sub=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$api/submit" \
        -H 'Content-Type: application/json' -d '{"task_name":"add","payload":{"a":1,"b":2}}' 2>/dev/null)
  printf '  t+%3ss  pending_pods=%-3s  submit=%s\n' "$el" "$pending" "${sub:-000}"
  sleep 10
done
wait "$drain_pid"; rc=$?
el=$(( $(date +%s) - t0 ))

echo
echo "drain exit $rc after ${el}s"
tail -5 "${here}/docs/gamedays/exp4-drain.log"
echo
echo "Pending pods on the surviving node, by namespace:"
kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null \
  | awk '{print $1}' | sort | uniq -c | sed 's/^/  /'
echo
echo "helios-prod after the drain:"
kubectl -n "$ns" get pods --no-headers | awk '{print "  " $1, $2, $3}'
echo
echo "smoke test on the surviving node:"
"$here/scripts/smoke.sh" "$api"
