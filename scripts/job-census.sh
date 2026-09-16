#!/usr/bin/env bash
#
# job-census.sh — count every job record by status.
#
#   ./scripts/job-census.sh [namespace]
#
# The chaos experiments need to know whether work was lost, and the metrics
# cannot say: a job that a worker popped and then died holding never reaches
# a terminal state, so it never increments any counter. It simply stops.
#
# The job store can say. Every job is written as `running` when a worker
# picks it up. After the queue has drained, any record still `running` is a
# job that was taken off the queue and never finished - lost work.
#
# Runs one Lua script inside Redis so it is a single round trip, not one
# GET per job. KEYS is blocking; fine on a test cluster with a few thousand
# records, not something to run against a busy production Redis.

set -uo pipefail

ns="${1:-helios-prod}"

read -r -d '' LUA <<'EOF'
local counts = {}
local keys = redis.call('KEYS', 'job:*')
for _, k in ipairs(keys) do
  local v = redis.call('GET', k)
  local s = v and string.match(v, '"status": "(%a+)"') or 'missing'
  counts[s] = (counts[s] or 0) + 1
end
local out = {}
for k, v in pairs(counts) do table.insert(out, k .. '=' .. v) end
table.insert(out, 'queued=' .. redis.call('ZCARD', 'task_queue'))
table.insert(out, 'delayed=' .. redis.call('ZCARD', 'delayed_queue'))
table.insert(out, 'dead_letter=' .. redis.call('LLEN', 'dead_letter_queue'))
return out
EOF

kubectl -n "$ns" exec deploy/redis -- redis-cli EVAL "$LUA" 0 \
  | tr -d '"' | sed 's/^[0-9]*) //' | sort
