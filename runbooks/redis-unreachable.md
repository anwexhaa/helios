# Runbook - Redis unreachable

The service cannot reach its only stateful dependency.

**Severity:** page
**Alerts:** `OrionRedisUnreachable`
**Last exercised:** 2026-09-16, game day 2 - Redis recovered in ~11s; the alert reached pending and correctly did not page. See [gamedays.md](../docs/gamedays.md#experiment-2--redis-killed).

## Symptom

`orion_redis_up` is 0 on at least one pod. `/submit` returns 500, `/ready` returns 503, and
`/health` stays 200 - that last one is deliberate, not a bug. See below.

Expect roughly 8 seconds per failed `/submit` and 4 seconds per scrape while this lasts. Those
are the bounded timeouts, and they are what stops a dependency outage becoming a total outage as
the worker pool fills with doomed requests.

## Verify

```bash
kubectl -n helios-prod get pods -l app.kubernetes.io/name=redis
kubectl -n helios-prod exec deploy/orion-api -- getent hosts redis
```

## Diagnose

| Check | Command | Meaning |
|-------|---------|---------|
| Is the pod running? | `kubectl -n helios-prod get pods -l app.kubernetes.io/name=redis` | Gone or CrashLooping is the simple case |
| Why did it die? | `kubectl -n helios-prod describe pod -l app.kubernetes.io/name=redis` | `OOMKilled` means the 256Mi limit was hit |
| Does DNS resolve? | `kubectl -n helios-prod exec deploy/orion-api -- getent hosts redis` | No answer means a Service or CoreDNS problem, not Redis |
| Is CoreDNS healthy? | `kubectl -n kube-system get pods -l k8s-app=kube-dns` | On a small cluster, app pods and CoreDNS share a node |

## Remediate

1. **If the pod is gone or crashlooping**, let the Deployment recreate it and watch:
   ```bash
   kubectl -n helios-prod rollout restart deploy/redis
   kubectl -n helios-prod rollout status deploy/redis
   ```
2. **If it was OOMKilled**, the 256Mi limit is too small for the queue depth being held. Raise it
   in `k8s/base/redis.yaml`. Do not raise it past what the node can honour.
3. **If DNS is the problem**, restarting Redis achieves nothing. Check CoreDNS.

**Expect the queue to be empty afterwards.** Redis here is deliberately ephemeral, with no
PersistentVolume, because Phase 4 kills it on purpose and persistence would make that experiment
measure the disk instead of the application. Jobs in flight are lost. That is a known and
accepted trade for this build, and the first thing to change if it were real.

## Why /health stays 200

Liveness deliberately does not check Redis. If it did, every API pod would fail liveness at the
same moment during a Redis outage and be restarted together - turning a recoverable dependency
problem into a full outage, and destroying the pods whose logs you need. Readiness does check
Redis, and correctly pulls pods out of the Service.

## Escalate

If Redis recovers but `orion_redis_up` stays 0, the problem is between the app and Redis - a
network policy, or a stale connection pool. Restart the API deployment.

## Aftermath

Record the recovery time. This is one of the four Phase 4 chaos experiments, so the measured
MTTR belongs in `docs/gamedays.md`.
