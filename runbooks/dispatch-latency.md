# Runbook - dispatch latency objective at risk

Jobs are waiting too long to be picked up.

**Severity:** ticket
**Alerts:** `OrionDispatchLatencyObjectiveAtRisk`
**Last exercised:** not yet - Phase 4 game day

## Symptom

Fewer than 95% of jobs were dispatched within 300 ms over the last hour.

This measures queue wait, not execution time. A slow *task* does not trigger it; a task that
sits unclaimed does. The distinction matters: the first is the task author's problem, the second
is ours.

## Verify

```promql
job:slo_latency_good:ratio_rate1h
histogram_quantile(0.95, sum by (le) (rate(orion_dispatch_latency_seconds_bucket[5m])))
```

## Diagnose

| Check | Meaning |
|-------|---------|
| Queue depth rising | More work arriving than the pool can take - a scaling problem |
| Depth flat but latency high | Workers busy with long tasks, not returning to poll |
| `orion_workers_alive` | Fewer workers than expected; check whether KEDA scaled down |
| `orion_workers_replaced_total` rising | Workers stalling and being replaced, losing throughput to churn |
| `orion_job_duration_seconds` p95 | A newly slow task can starve the pool without failing anything |

## Remediate

1. **Scale the worker deployment.** Addresses the common case directly:
   ```bash
   kubectl -n helios-prod scale deploy/orion-worker --replicas=6
   ```
2. **If KEDA scaled down while the queue was non-empty**, the ScaledObject thresholds are wrong,
   not the cluster. Check `listLength` and `cooldownPeriod`.
3. **If one task type dominates `orion_job_duration_seconds`**, it is starving the pool. Raising
   `WORKER_COUNT` gives each pod more threads without more pods.

## Not an incident

If queue depth is high but latency is inside the objective, nothing is wrong. A deep queue being
drained quickly is the system working. Do not scale in response to depth alone - that is what
the autoscaler is for, and doing it by hand teaches the wrong reflex.

## Aftermath

If this fired because the autoscaler was too slow rather than absent, the fix belongs in the
ScaledObject, not in a manual scale. Record it in `docs/gamedays.md`.
