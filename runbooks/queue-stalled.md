# Runbook - queue stalled

Jobs are being accepted and none are completing.

**Severity:** page
**Alerts:** `OrionQueueStalled`, `OrionNoWorkersRunning`
**Last exercised:** not directly. Game day 1 killed a worker without stalling the queue, and found that the dead pod's in-flight jobs were lost rather than stalled - a failure this runbook cannot detect. See [gamedays.md](../docs/gamedays.md#experiment-1--worker-pod-killed).

## Symptom

Queue depth is above zero and `orion_jobs_processed_total` has not moved for five minutes.

The API is almost certainly healthy. This is the failure mode where every probe is green,
Kubernetes reports the deployment as successful, and no work is being done - which is exactly
why the smoke test submits a real job rather than trusting readiness.

## Verify

```bash
kubectl -n helios-prod get pods -l app.kubernetes.io/component=worker
kubectl -n helios-prod logs deploy/orion-worker --tail=20
```

If queue depth is climbing while worker pods report Ready, the alert is real.

## Diagnose

| Check | Command | Meaning |
|-------|---------|---------|
| Are there workers at all? | `kubectl -n helios-prod get deploy orion-worker` | 0 replicas means KEDA scaled to zero, or the deployment was removed |
| Are they Ready? | `kubectl -n helios-prod describe deploy orion-worker` | Not Ready usually means Redis is unreachable |
| Are they wedged? | `kubectl -n helios-prod logs deploy/orion-worker --tail=50` | No output at all suggests a blocked thread |
| Is Redis up? | `orion_redis_up` on the dashboard | If 0, use [redis-unreachable.md](redis-unreachable.md) instead |
| Task registered? | Look for `Task 'x' not registered` in the logs | A job naming an unknown task fails immediately and retries forever |

## Remediate

Least destructive first.

1. **Confirm it is not Redis.** If `orion_redis_up` is 0, this is the wrong runbook.
2. **Scale the workers by hand.** This restores service and tells you whether KEDA is the
   problem:
   ```bash
   kubectl -n helios-prod scale deploy/orion-worker --replicas=4
   ```
3. **If pods are Ready but idle, restart them.** The pool replaces stalled threads on its own,
   so a whole pod being stuck points at something below it:
   ```bash
   kubectl -n helios-prod rollout restart deploy/orion-worker
   ```
4. **If the queue is full of jobs naming an unregistered task**, they fail and retry forever.
   Let them reach the dead letter queue rather than cycling.

**Do not delete the queue key.** Everything in it is work someone submitted and was told had
been accepted. The dead letter queue exists so failed work stays inspectable; deleting the queue
throws it away silently.

## Escalate

No escalation path on this project. If unresolved after 30 minutes, scale workers to a fixed
count, suspend the KEDA ScaledObject so it cannot scale them back down, and investigate with the
service running.

## Aftermath

Record in `docs/gamedays.md` if this was an exercise, or open a postmortem if it was real. Note
the error budget consumed. If this runbook was wrong or slow, fix it now, while it is fresh.
