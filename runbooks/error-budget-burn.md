# Runbook - error budget burning

The service is failing requests fast enough to threaten the monthly objective.

**Severity:** page for fast burn, ticket for slow burn
**Alerts:** `OrionErrorBudgetFastBurn`, `OrionErrorBudgetSlowBurn`
**Last exercised:** not yet - Phase 4 game day

## Symptom

Fast burn: the 1h and 5m error ratios are both above 6.72%, consuming 2% of the 28-day budget
every hour. At that rate the whole budget is gone in about two days.

Slow burn: the 6h and 30m ratios are both above 2.8%. Not urgent, but it will not hold for a
month.

## Verify

Open the Grafana **Orion SLO** dashboard. Confirm budget-remaining is falling and burn rate is
above the threshold line. If only the long window is elevated and the short one has recovered,
the incident is already over and the alert will clear on its own.

## Diagnose

The burn alert says the promise is being broken, not why. Work down the layers:

| Check | Where | Meaning |
|-------|-------|---------|
| `orion_redis_up` | dashboard | 0 means use [redis-unreachable.md](redis-unreachable.md) |
| Errors by route | `sum by (route, status) (rate(orion_http_requests_total{status=~"5.."}[5m]))` | Concentration on one route narrows it fast |
| Recent deploy? | `kubectl -n helios-prod rollout history deploy/orion-api` | A deploy just before the burn began is the first suspect |
| Pod restarts | [pod-restarts.kql](../docs/kql/pod-restarts.kql) | OOMKilled or CrashLoopBackOff |
| Node health | [node-pressure.kql](../docs/kql/node-pressure.kql) | Prometheus cannot report on a node that is gone |

## Remediate

1. **If a deploy correlates with the start, roll it back.** Fastest route to restoring service;
   diagnose afterwards from a healthy state:
   ```bash
   kubectl -n helios-prod rollout undo deploy/orion-api
   kubectl -n helios-prod rollout status deploy/orion-api
   ```
2. **If Redis is the cause**, follow that runbook - this one cannot fix it.
3. **If errors concentrate on one non-essential route**, consider shedding it rather than letting
   it consume the budget for everything else.

## Budget policy

When the budget is exhausted, feature work stops and reliability work starts until it recovers.
That is the point of a budget rather than a target: it turns "be more careful" into a decision
with a trigger.

For a solo project: no new phases until the burn is understood and fixed.

## Escalate

None available. If unresolved in an hour, roll back to the last known-good image tag by git SHA
and stabilise before investigating further.

## Aftermath

Open a postmortem in `docs/postmortems/`. Record budget consumed, timeline, root cause, actions.
A burn alert that fired and was not written up is a budget spent with nothing learned.
