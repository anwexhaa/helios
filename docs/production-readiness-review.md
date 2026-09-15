# Production readiness review — Orion Queue

A review of the service Helios is going to operate, carried out before any infrastructure was
provisioned. Source reviewed: `github.com/anwexhaa/orion-queue` at clone on 2026-09-15.

The point of a PRR is to find out what the platform will have to work around *before* the
platform exists. Six findings, none of them surprising for a service that has only ever run on
a developer's laptop.

**Current decision: the application is not being changed yet.** Helios proceeds with
infrastructure first; these findings are the backlog that has to clear before the service can
actually run in the cluster.

## Findings

| # | Finding | Severity | Blocks |
|---|---------|----------|--------|
| F1 | No Dockerfile. `docker-compose.yml` starts Redis only; the app runs on the host | Blocker | Phase 1 first deploy |
| F2 | `requirements.txt` is UTF-16LE, not UTF-8 | Blocker | Any Linux image build |
| F3 | Redis host hardcoded to `localhost` in four files | Blocker | Any deployment to Kubernetes |
| F4 | No `/health` endpoint | Blocker | Probes, Phase 2 smoke test |
| F5 | API, worker pool and scheduler run in one process | Blocker | Phase 4 worker autoscaling |
| F6 | `/metrics` returns JSON, not Prometheus exposition format | Major | Phase 3 scraping |

### F1 — No Dockerfile

`docker-compose.yml` defines a single service, `redis:7-alpine`. The application itself is
started by hand with `python main.py`. There is no image to deploy.

*Needs:* a multi-stage Dockerfile running as a non-root user, with separate entrypoints for the
API and the worker (see F5).

### F2 — requirements.txt encoding

```
$ file requirements.txt
requirements.txt: Unicode text, UTF-16, little-endian text, with CRLF line terminators
```

Written by a PowerShell `>` redirect, which defaults to UTF-16LE. `pip install -r` inside a
Linux build fails to parse it. Related: [[powershell-51-no-chaining]] — the same shell default
caused an earlier problem.

*Needs:* re-save as UTF-8, and pin `prometheus-client` while there (F6).

### F3 — Hardcoded Redis host

```
api.py:10             redis.Redis(host="localhost", port=6379, ...)
main.py:11            redis.Redis(host="localhost", port=6379, ...)
benchmark.py:13       redis.Redis(host="localhost", port=6379, ...)
priority_queue.py:7   def __init__(self, host="localhost", port=6379, ...)
```

In a pod, `localhost` is the pod itself. Redis will be a Service at
`redis.helios-<env>.svc.cluster.local`.

*Needs:* `REDIS_HOST` and `REDIS_PORT` read from the environment, defaulting to localhost so
local development is unaffected.

### F4 — No health endpoint

The API exposes `/submit`, `/status/{job_id}` and `/metrics`. Kubernetes needs a liveness probe
(is the process wedged) and a readiness probe (can it reach Redis). Phase 2's smoke test needs
the same endpoint.

*Needs:* `/health` returning 200 only when the Redis round-trip succeeds. A readiness probe that
returns 200 while the dependency is down is worse than no probe at all — it routes traffic into
a pod that cannot serve it.

### F5 — Single process for API, workers and scheduler

`main.py` starts the `DelayedQueueScheduler`, then a `WorkerPool` of four threads, then uvicorn
— all in one process. The pool's heartbeat monitor respawns dead worker threads, which is good
engineering inside a process and invisible to Kubernetes outside it.

Scaling the API also scales the workers, and vice versa. Worse, KEDA cannot act on worker
backlog at all, because there is no worker deployment to scale.

*Needs:* two entrypoints and two deployments, `orion-api` and `orion-worker`, against the same
image. The scheduler is a singleton and belongs in its own single-replica deployment, or as a
leader-elected component of the worker.

### F6 — Metrics format

`/metrics` returns `{"queue_size": N, "dead_jobs": N}` as JSON. Prometheus needs the text
exposition format.

*Needs:* `prometheus-client`, exposing at minimum queue depth, dispatch latency as a histogram,
jobs by terminal status, and retry counts.

**Correction to the original plan:** the Helios plan said to wire up "Orion Queue's existing
OpenTelemetry metrics". There is no OpenTelemetry in this service — that is the Spoolr project.
Phase 3 has to add instrumentation, not connect to it.

## Consequence for Phase 4

`priority_queue.py` stores jobs in a Redis **sorted set** (`zadd` / `zpopmax` / `zcard`) under
the key `task_queue`, scored by priority. It is not a list.

KEDA's `redis` scaler measures `LLEN` and would report zero forever against a sorted set. The
priority ordering is the substance of this project, so the queue stays a sorted set and the
scaler changes instead:

- **`metrics-api` scaler** against the existing `/metrics` JSON — works today, no Prometheus
  needed
- **`prometheus` scaler** against queue depth — preferred once Phase 3 is in place, because it
  scales on the same number the SLO dashboard shows

Recorded as decision D6.
