# Production readiness review — Orion Queue

A review of the service Helios is going to operate, carried out before any infrastructure was
provisioned. Source reviewed: `github.com/anwexhaa/orion-queue` at clone on 2026-09-15.

The point of a PRR is to find out what the platform will have to work around *before* the
platform exists. Six findings, none of them surprising for a service that has only ever run on
a developer's laptop.

**Status: all six findings are addressed** on the `feat/kubernetes-readiness` branch of
orion-queue, not yet merged or pushed. The sections below describe each finding as it was
found; the resolution is recorded at the end of each.

## Findings

| # | Finding | Severity | Blocks | Status |
|---|---------|----------|--------|--------|
| F1 | No Dockerfile. `docker-compose.yml` starts Redis only; the app runs on the host | Blocker | Phase 1 first deploy | Fixed |
| F2 | `requirements.txt` is UTF-16LE, not UTF-8 | Blocker | Any Linux image build | Fixed |
| F3 | Redis host hardcoded to `localhost` in four files | Blocker | Any deployment to Kubernetes | Fixed |
| F4 | No `/health` endpoint | Blocker | Probes, Phase 2 smoke test | Fixed |
| F5 | API, worker pool and scheduler run in one process | Blocker | Phase 4 worker autoscaling | Fixed |
| F6 | `/metrics` returns JSON, not Prometheus exposition format | Major | Phase 3 scraping | Fixed |
| F7 | Worker never persists terminal job status back to Redis | Major | Accurate `/status/{id}` | Fixed |
| F8 | Heartbeat monitor crashes when requeueing a stalled worker's job | Blocker | Self-healing worker pool | Fixed |

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

## F7 — Terminal job status is never written back to Redis

Found while instrumenting the worker, after the original six.

`api.py` writes `job:{id}` to Redis at submission time. `worker.py` then mutates `job.status`
in memory as the job runs and completes, but never writes it back. `GET /status/{job_id}`
therefore reports `pending` for every job, forever, including ones that finished successfully
or landed in the dead letter queue.

*Fixed.* A `JobStore` now owns the `job:{id}` key and is used by both the API and the worker,
which persists on every transition. Records carry a 24-hour TTL — without one, every job ever
submitted leaves a permanent Redis key behind. Saves never raise: a worker must not fail a job
it executed successfully because a status write did not land.

## F8 — The heartbeat monitor could not requeue a stalled worker's job

Found while fixing F7, and the most serious finding in this review.

`worker_pool._monitor` assigned the string `"pending"` to `current_job.status`, where the rest
of the codebase uses the `JobStatus` enum. `Job.to_dict()` reads `status.value`, so the very
next statement — `queue.push(job)` — raised `AttributeError: 'str' object has no attribute
'value'`.

That exception was raised inside the monitor's daemon thread, which had no handler. The first
time a worker actually stalled, the pool stopped replacing stalled workers entirely, and
nothing reported it. Silent, and permanent for the life of the process.

This matters beyond the bug itself: the self-healing worker pool is the headline claim on the
resume this project supports. The mechanism was real, but the recovery path it existed to
perform would have failed the first time it was needed.

*Fixed.* Assigns `JobStatus.PENDING`. The monitor loop body is wrapped so a future failure
costs one cycle instead of ending self-healing for good, and says so on stdout. `check_once()`
is extracted from the loop so the path is directly testable rather than only observable by
waiting on a background thread, and replacements increment
`orion_workers_replaced_total` so a pool quietly churning through stalled workers is visible.

Three regression tests cover it: replacement happens, the requeued job survives serialisation,
and healthy workers are left alone.

## Resolution

Fixed on `feat/kubernetes-readiness` in orion-queue. Not merged, not pushed.

| Finding | Resolution |
|---------|-----------|
| F1 | Multi-stage `Dockerfile`, non-root uid 10001, one image for all three roles, `PYTHONUNBUFFERED` so logs reach `kubectl logs` |
| F2 | Converted to UTF-8 with all 15 original pins preserved; `prometheus-client` added |
| F3 | New `config.py` reads every setting from the environment, defaulting to the old hardcoded values; all four call sites converted |
| F4 | `/health` (liveness, no dependency check) and `/ready` (readiness, Redis round-trip) on all three processes |
| F5 | Split into `api_main.py`, `worker_main.py` and `scheduler_main.py`, with SIGTERM draining in the worker; `main.py` kept as the local all-in-one |
| F6 | `metrics.py` exposes ten Prometheus collectors; the original JSON moved to `/stats` for KEDA's metrics-api scaler |

The dispatch latency histogram carries an explicit bucket boundary at 0.3s so the Phase 3
latency SLI — 95% of jobs dispatched within 300 ms — can be computed exactly rather than
interpolated between buckets. If the SLO target changes, `DISPATCH_BUCKETS` has to change with
it.
