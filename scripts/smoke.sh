#!/usr/bin/env bash
#
# smoke.sh <base-url> — prove a deployment actually works.
#
# Runs after every deploy, in every environment. A rollout reporting Ready
# only means the containers started and their probes passed; it says nothing
# about whether a job submitted through the API is ever executed. That is the
# thing this checks, and it is the signal the pipeline rolls back on.
#
#   ./scripts/smoke.sh http://localhost:8080
#
# Exits non-zero on the first failure, with the reason on stderr.

set -uo pipefail

BASE="${1:-}"
TIMEOUT="${SMOKE_TIMEOUT:-45}"

if [ -z "$BASE" ]; then
  echo "usage: smoke.sh <base-url>" >&2
  exit 2
fi

BASE="${BASE%/}"
failures=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

status_of() {
  # No -f here. With -f curl exits non-zero on a 4xx, which would trigger the
  # fallback and concatenate it onto the code curl already printed. Without
  # it, curl reports the real status and only writes 000 when the connection
  # itself failed.
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

echo "Smoke test against ${BASE}"

# --- 1. Liveness -----------------------------------------------------------
code="$(status_of "${BASE}/health")"
if [ "$code" = "200" ]; then pass "/health returned 200"; else fail "/health returned ${code}"; fi

# --- 2. Readiness ----------------------------------------------------------
# A 503 here means the service is up but cannot reach Redis, which is a
# meaningfully different failure from the process being down.
code="$(status_of "${BASE}/ready")"
if [ "$code" = "200" ]; then
  pass "/ready returned 200"
else
  fail "/ready returned ${code} (dependency unreachable?)"
fi

# --- 3. Metrics are scrapeable --------------------------------------------
body="$(curl -fsS --max-time 10 "${BASE}/metrics" 2>/dev/null)"
if printf '%s' "$body" | grep -q '^# HELP orion_'; then
  pass "/metrics serves Prometheus exposition format"
else
  fail "/metrics did not return Prometheus format"
fi

# --- 4. A job submitted is actually executed -------------------------------
# The real test. Everything above can pass while no work is being done.
response="$(curl -fsS --max-time 10 -X POST "${BASE}/submit" \
  -H 'Content-Type: application/json' \
  -d '{"task_name":"add","payload":{"a":2,"b":40},"priority":20}' 2>/dev/null)"

job_id="$(printf '%s' "$response" | sed -n 's/.*"job_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

if [ -z "$job_id" ]; then
  fail "POST /submit did not return a job_id (response: ${response:-<empty>})"
else
  pass "POST /submit accepted a job (${job_id})"

  deadline=$((SECONDS + TIMEOUT))
  final=""
  while [ $SECONDS -lt $deadline ]; do
    record="$(curl -fsS --max-time 10 "${BASE}/status/${job_id}" 2>/dev/null)"
    state="$(printf '%s' "$record" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    case "$state" in
      done|failed|dead) final="$state"; break ;;
    esac
    sleep 1
  done

  if [ "$final" = "done" ]; then
    pass "job reached done within ${TIMEOUT}s"
  elif [ -n "$final" ]; then
    fail "job reached terminal state '${final}', expected done"
  else
    fail "job never left pending within ${TIMEOUT}s — workers may not be consuming"
  fi
fi

# --- 5. Unknown jobs 404 ---------------------------------------------------
code="$(status_of "${BASE}/status/definitely-not-a-real-job")"
if [ "$code" = "404" ]; then
  pass "unknown job returns 404"
else
  fail "unknown job returned ${code}, expected 404"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "Smoke test FAILED: ${failures} check(s) did not pass." >&2
  exit 1
fi

echo "Smoke test passed."
