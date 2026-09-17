# Runbook - a worker died holding jobs

A worker process stopped renewing the leases on the jobs it held, and the reaper
put those jobs back on the queue.

**Severity:** ticket
**Alerts:** `OrionWorkerDiedHoldingJobs`
**Last exercised:** locally, with `scripts/crash-test.sh` in orion-queue - a SIGKILLed
worker's four jobs were reaped and completed every run. Not yet on a cluster.

## What already happened

Nothing was lost. Each job was requeued with its original priority and will be run by
another worker. The alert is a ticket rather than a page for that reason.

Two things are still worth knowing:

- **Some of those jobs may have run twice.** A job that was nearly finished when its worker
  died will be run again from the start. Tasks are meant to be idempotent; if one is not,
  this is where it shows.
- **Something killed a worker.** Leases do not expire on their own while a worker is alive.

## Diagnose

| Check | Command | Meaning |
|-------|---------|---------|
| Why did the pod stop? | `kubectl -n helios-prod get events --sort-by=.lastTimestamp \| grep orion-worker` | `Killing`, `Evicted`, `OOMKilled`, `Preempting` |
| OOMKilled? | `kubectl -n helios-prod get pods -l app.kubernetes.io/name=orion-worker -o jsonpath='{..lastState.terminated.reason}'` | Raise the memory limit, or find the task that grew |
| Evicted by a drain or scale-down? | `kubectl get events -A \| grep -i -E "evict\|drain\|scaledown"` | Expected during node maintenance; check the worker drained first |
| Duplicates happening? | `orion_lease_ack_late_total` on the dashboard | Rising means leases expire on workers that are still alive |

## If duplicates are rising

`orion_lease_ack_late_total` counts workers that finished a job after its lease had already
expired. That is not a dead worker - it is a live one being too slow for `LEASE_SECONDS`.

1. Compare `orion_job_duration_seconds` p99 against `LEASE_SECONDS` (default 30).
2. Renewal happens every third of the lease, so a lease should never expire on a healthy
   worker. If it does, suspect Redis latency or long pauses in the worker process.
3. Raise `LEASE_SECONDS` in `k8s/base/configmap.yaml`. Longer leases mean slower recovery
   from a real crash: worst case is `LEASE_SECONDS + REAP_INTERVAL`.

## Graceful shutdowns should not fire this

A worker that receives SIGTERM drains: it finishes its jobs and acknowledges them before
exiting, so the reaper finds nothing. If this alert fires during a planned rollout or KEDA
scale-down, the drain is not completing - check that `terminationGracePeriodSeconds` (40)
still exceeds the worker's own drain window (20).
