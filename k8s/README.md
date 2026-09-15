# k8s

Kubernetes manifests, laid out as a kustomize base with one overlay per environment.

```
base/          shared by every environment
overlays/dev   overlays/test   overlays/prod
```

Environments differ only by overlay. If something is true in production and not in dev, it is
a committed file, never a `kubectl edit`.

## What gets deployed

| Resource | Notes |
|----------|-------|
| `orion-api` | Deployment + Service + PodDisruptionBudget |
| `orion-worker` | Deployment. KEDA takes over its replica count in Phase 4 |
| `orion-scheduler` | Deployment, `Recreate` strategy, exactly one replica |
| `redis` | Deployment + Service, ephemeral |
| `orion-config` | ConfigMap holding every environment variable the service reads |

## Rendering

No cluster needed:

```bash
kubectl kustomize k8s/overlays/dev
```

Each overlay renders eight resources. Do this before every commit that touches a manifest —
it catches a broken patch path in a second, where a pipeline would take minutes.

Applying:

```bash
kubectl apply -k k8s/overlays/dev
```

## Decisions worth knowing

**The scheduler uses `Recreate`, not `RollingUpdate`.** A rolling update would briefly run two
scheduler pods. `DelayedQueue.poll` pushes a due job onto the main queue before removing it
from the delayed set, so two schedulers requeue the same job twice. A few seconds of downtime
during a deploy is the correct trade.

**Liveness probes do not touch Redis; readiness probes do.** A liveness probe that fails during
a Redis outage restarts every pod simultaneously and turns a recoverable dependency problem
into a full outage. Readiness is the probe that should fail — it removes the pod from the
Service without killing it.

**The worker gets a 40-second termination grace period.** It drains on SIGTERM, letting
in-flight jobs finish rather than dropping them back on the queue. Its own grace window is 20
seconds, so Kubernetes must allow more than that before SIGKILL. When KEDA scales the pool
down in Phase 4, this is what stops work being lost.

**Redis is ephemeral, with no PersistentVolume.** Phase 4 kills this pod deliberately to watch
the service recover; persistence would make that experiment measure the disk instead of the
application. A real deployment would use Azure Cache for Redis.

**Resource requests are set honestly on every container.** The cluster autoscaler reasons about
requests, not actual usage. Containers without them are invisible to it, and Phase 4's
autoscaling demonstration would not work.

**The image tag is `dev`, never `latest`.** The pipeline replaces it with the git SHA:

```bash
kustomize edit set image orion-queue=$ACR/orion-queue:$GIT_SHA
```

You cannot tell what is running from a tag called `latest`.

## Not here yet

- `ScaledObject` for KEDA — Phase 4
- ServiceMonitor for Prometheus — Phase 3; the pods already carry
  `prometheus.io/scrape` annotations
- Ingress — the API is ClusterIP for now; Phase 2 decides how it is reached
- Workload identity ServiceAccount — nothing needs an Azure credential yet
