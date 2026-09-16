#!/usr/bin/env bash
#
# run-exp2.sh — kill Redis and measure how the service degrades and recovers.
#
# Records, second by second, what a user would see: whether /ready is serving
# and whether a real submission succeeds. The recovery time that matters is
# until a real job round-trips again, not until the Redis pod reports Ready.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
api="${API:-http://localhost:18080}"
ns=helios-prod

code_of() {
  local c
  c="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$@" 2>/dev/null)"
  printf '%s' "${c:-000}"
}

submit() {
  code_of -X POST "$api/submit" -H 'Content-Type: application/json' \
    -d '{"task_name":"add","payload":{"a":1,"b":2}}'
}

echo "baseline: ready=$(code_of "$api/ready") submit=$(submit)"

t0=$(date +%s)
echo "injecting at $(date -u +%H:%M:%S)Z"
kubectl apply -f "$here/chaos/02-redis-pod-kill.yaml" >/dev/null

first_fail=""
redis_ready_at=""
recovered_at=""

while :; do
  now=$(date +%s); el=$((now - t0))
  [ "$el" -gt 240 ] && { echo "gave up after 240s"; break; }

  rdy=$(code_of "$api/ready")
  sub=$(submit)
  rpod=$(kubectl -n "$ns" get pods -l app.kubernetes.io/name=redis \
         -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)

  printf '  t+%3ss  ready=%s  submit=%s  redis_pod_ready=%s\n' "$el" "$rdy" "$sub" "${rpod:-none}"

  if [ -z "$first_fail" ] && [ "$sub" != "200" ]; then first_fail=$el; fi
  if [ -z "$redis_ready_at" ] && [ "$rpod" = "true" ] && [ "$el" -gt 3 ]; then redis_ready_at=$el; fi
  if [ -n "$first_fail" ] && [ "$sub" = "200" ] && [ "$rdy" = "200" ]; then
    recovered_at=$el
    break
  fi
  sleep 2
done

echo
echo "first failed submission : t+${first_fail:-never}s"
echo "redis pod ready again   : t+${redis_ready_at:-?}s"
echo "submissions recovered   : t+${recovered_at:-never}s"
echo
echo "smoke test after recovery:"
"$here/scripts/smoke.sh" "$api"
