# Game days

Results from the chaos experiments in [`chaos/`](../chaos/), run 2026-09-16 against a real
two-node AKS cluster (Standard_B2s_v2, free-trial subscription, 4 vCPU cap).

Raw evidence for each is in [`gamedays/`](gamedays/). The numbers below come from the cluster,
not from estimates — several estimates made before running these turned out to be wrong, and
where that happened it is said.

## Results

| # | Experiment | Detected | Recovered | Budget burned | Hypothesis |
|---|-----------|----------|-----------|---------------|-----------|
| 1 | Worker pod killed | **Not detected.** No alert, no metric moved | 15s — a queued Pending worker took the freed slot | 0 | **Falsified** — 4 jobs lost. Since fixed |
| 2 | Redis killed | `orion_redis_up` → 0 at once; alert reached *pending*, not firing | ~11s — Deployment recreated Redis | **SLI recorded 0 — a bug.** 12 after the fix | Confirmed, but exposed two SLI blind spots |
| 3 | Redis +500ms | Latency SLI collapsed within ~30s; alert reached *firing* | Reverted at the 5m chaos duration | 0 availability; latency objective breached | Partly falsified — probes did not stay green |
| 4 | Node drained | No user-visible failure | Drain 103s; full recovery on uncordon | 0 | Confirmed for the app; the *platform* degraded |

**Detected** means until an alert or metric reported it — not until it was spotted on a
dashboard already being watched. **Recovered** means until a real job round-tripped, not until a
pod showed Ready.

---

## Experiment 1 — worker pod killed

**Hypothesis:** a worker dying mid-job costs nothing user-visible; its job is finished during the
SIGTERM drain or left on the queue.

**Falsified.** Four jobs were lost.

After 8,999 jobs and a full drain with every worker idle, the job store read `done=8995`,
`running=4`. Four records permanently stuck in `running` — exactly one pod's worth,
`WORKER_COUNT=4`. Their submitters received a 200 and a job id; the work never happened.

Three things combined:

- Chaos Mesh `pod-kill` defaults to **grace period 0**, so there was no SIGTERM and no drain
- `zpopmax` **removes** a job from Redis before the worker processes it
- The heartbeat monitor that requeues stalled jobs **lives in the same pod**, so it died too

**The pool's self-healing only works within a process.** It recovers a wedged thread; it cannot
recover the work of a dead pod. Nothing alerted, because a job that never finishes never
increments any counter — it simply stops.

**Also learned:** killing a pod did not reduce capacity. The cluster was at its CPU ceiling with
two workers already Pending; the freed CPU went to one of those, and the replacement joined the
back of the Pending queue. "Recovered in 15s" was a queued pod becoming Ready, not a replacement.

**Status: fixed; verified locally, not yet on a cluster.**

orion-queue now uses **leased fetch**. One Lua script pops a job and records a lease in a
processing set; the pool renews leases while jobs run; a reaper in the scheduler requeues any
lease that expires. The lease lives in Redis, so it survives the pod. Delivery is now
at-least-once — the same trade SQS visibility timeouts and Sidekiq's reliable fetch make.

Verified with `scripts/crash-test.sh` in orion-queue, which reproduces this experiment without a
cluster by SIGKILLing a 4-thread worker holding a full batch:

| Code | Runs | Lost |
|------|------|------|
| Before | 4 | **4, every run** |
| After | 7 | **0, every run** — exactly 4 leases reaped each time |

The run against the old code is the control. A graceful SIGTERM reaped nothing, as it should:
the worker finished and acknowledged its own jobs.

Leasing initially halved benchmark throughput, because every job needed a separate ack. The
ack now rides on the next pop in the same script, and throughput is back within noise of the
original.

The silence is fixed too: `orion_leases_expired_total` counts every recovered job, and
`OrionWorkerDiedHoldingJobs` opens a ticket when it moves.

**Still to do:** re-run this experiment on the cluster.

## Experiment 2 — Redis killed

**Hypothesis:** the service degrades cleanly and fast rather than hanging.

**Confirmed** — Redis was back in ~11s, `/health` stayed 200, and `OrionRedisUnreachable`
reached *pending* but never *firing*. That last part is the design working: an 11-second
self-healing blip should not page anyone, and `for: 2m` exists for exactly that.

Every job record from before the restart was lost, as documented — Redis is ephemeral here.

**It also exposed the two most important findings of the day.**

### The availability SLI recorded zero errors for a real outage

Four real 500s were served. The availability SLI saw none.

```
raw orion_http_requests_total{status="500"}   = 4
increase(...{status="500"}[10m])              = 0
first sample of that series                   : 12:43:18Z, value 4
```

A labelled Prometheus counter series does not exist until its first `.inc()`. The
`status="500"` series was born mid-outage, already at 4, between two scrapes. Prometheus never
saw it at zero, so `increase()` computed 4 − 4 = 0.

In practice: **the first burst of any status code a process has never produced is invisible** —
which is to say, the first outage.

**Fixed and re-verified.** Series are now created at zero on startup. Re-running the same
experiment against the fixed image:

| | Before | After |
|---|---|---|
| Real 500s served | 4 | 12 |
| What the SLI saw | **0** | **12.6** |
| Error ratio, 5m | 0 | 24% |

A regression test asserts the series exists at zero before any error, and was confirmed to fail
with the fix removed.

### A server-side SLI cannot see failures that never reach the server

The load generator saw **586 failures out of 2,397 requests — 24.45%**. The application served
**4** 500s. The other 582 never reached the application as completed requests.

The data cannot separate the causes — connection resets on the port-forward tunnel, or requests
abandoned while blocked on Redis. What it does establish is structural: an availability SLI
measured inside the application only counts requests the application finished.

**Status: open.** The fix is measuring closer to the user — ingress or load balancer metrics, or
running the smoke test on a schedule as a synthetic probe.

## Experiment 3 — Redis +500ms

**Hypothesis:** availability holds, the latency objective collapses, every probe stays green.

| Part | Result |
|------|--------|
| Availability holds | **Confirmed** — server error ratio 0.000 throughout |
| Latency collapses | **Confirmed** — jobs within 300ms fell from 90% to 0% |
| Latency alert fires | **Confirmed**, with a caveat: its 1h window also contains the earlier load test's breach, so the firing cannot be attributed to this experiment alone |
| Every probe stays green | **Falsified** |

Real client-side latency went from 5–9ms to a **p95 of 1.48s**. (The server-side p95 of 2.36s is
an interpolation artifact: the HTTP histogram reuses the dispatch buckets, which jump from 1.0s
to 2.5s, so latency in that range is smeared across the gap.)

**Why the probes failed.** Every worker and the scheduler flapped NotReady together. Their
`/ready` made two Redis round trips — a ping and a queue-depth read — on the main five-second
client. At +500ms each, that is about one second: the kubelet's default probe timeout.

The API survived only because its `/ready` had already been reduced to one call on a
one-second client. Workers were unaffected in practice because they have no Service; a NotReady
worker keeps pulling jobs. **The same pattern on the API would have removed every replica from
the Service at once, over latency the pods could still serve through** — turning a slow
dependency into a full outage.

**Fixed and re-verified.** Readiness is now one ping on a fast client, with no metrics work in
the health path. Re-running the injection:

| | Before | After |
|---|---|---|
| `pods_not_ready` samples | 2, 1, 0, 2, 2, 2, 1, 1, 2, 0 | 0, 0, 0, 0, 0, 0, 0 |
| Worker / scheduler probe failures | throughout | **0** |

One residual: a single API probe failure, absorbed by `failureThreshold: 2`. The kubelet timeout
(1s) equalled the app's Redis timeout (1s), leaving no headroom. Readiness `timeoutSeconds` is
now 3 so the app answers 503 itself rather than the kubelet timing out. **Not yet re-verified on
a cluster.**

## Experiment 4 — node drained

**Hypothesis:** pods reschedule, the PodDisruptionBudget protects availability, and pods may be
left Pending because one node must hold everything.

**Confirmed for the application.** Every submission returned 200 throughout. All five
application pods rescheduled and the smoke test passed on the surviving node. A PDB visibly did
its job — `Cannot evict pod as it would violate the pod's disruption budget` — then the eviction
succeeded once the other replica was ready.

**The platform degraded instead.** Pending at the end of the drain: 2 KEDA pods, 1 monitoring
pod (Prometheus), 1 kube-system pod. So during the node loss, **autoscaling was down and
monitoring was blind** — while the application carried on.

That is decision D10 demonstrated rather than argued: had KEDA used the `prometheus` scaler,
worker scaling would have stopped at exactly this moment.

**The deeper finding: replicas were not spread.** Both CoreDNS replicas, both konnectivity
agents and both metrics-server replicas were on the drained node. The cluster started with one
node; every system pod landed there; when the autoscaler added the second node, nothing moved.
Kubernetes does not rebalance running pods. **"Two replicas for high availability" was illusory**
— the PDBs only slowed the eviction down.

**Status: open.** Fixable with topology spread constraints on the workloads that matter, or the
descheduler for pods already placed.

---

## Autoscaling under load

k6 at 30 jobs/s for 5 minutes, `slow_task` of 2s. Full samples in
[`gamedays/scale-test.csv`](gamedays/scale-test.csv).

| Elapsed | Queue depth | KEDA wanted | Running | Pending |
|---------|-------------|-------------|---------|---------|
| 0s | 0 | 1 | 1 | 0 |
| 32s | 265 | 2 | 2 | 0 |
| 47s | 598 | 4 | 4 | 0 |
| 62s | 905 | 8 | 8 | 0 |
| 77s → 300s | 1,105 → 4,236 | **12** | **8** | 2 |

KEDA reached its ceiling of 12 within 77 seconds. The cluster could place 8:

```
default-scheduler   0/2 nodes are available: 2 Insufficient cpu
cluster-autoscaler  pod didn't trigger scale-up: 1 max node group size reached
```

The namespace quota was at 1670m of 3000m — the limit was node capacity, not the quota. This is
decision D8 observed rather than predicted.

The **cluster autoscaler** had already added the second node before the load test began —
triggered organically, by the production pods themselves not fitting on the first:

```
pod/orion-api   triggered scale-up: [{aks-system-30472714-vmss 1->2 (max: 2)}]
```

**Throughput matched the arithmetic.** With 8 workers of 4 threads each draining 2-second jobs,
the predicted drain rate was 16/s. Measured: 15.5/s. With 30/s arriving, the queue grew at about
14/s — also as predicted.

**Submit latency:** 24ms p95 measured server-side by the application's own histogram. k6
reported 465ms, and the ~440ms difference is `kubectl port-forward`, not the service. The API
used at most 47m of CPU and was throttled 0.18% of the time.

**Not captured:** the scale-down. The sampler ended 45 seconds after the queue emptied, inside
the 180-second stabilisation window. KEDA was later observed at 1 replica, so scale-down did
happen, but its timing was not measured.

## Capacity — the estimate that kept being wrong

The Phase 4 worker sizing was revised three times. The cause, measured on the running cluster:

| | Estimated | Measured |
|---|---|---|
| AKS `kube-system` CPU requests | 400m | **1,880m** |
| Monitoring stack | 380m | 280m |
| Allocatable per Standard_B2s_v2 node | 1,500m | 1,900m |

**Half the cluster's CPU is taken by the platform before any workload runs**, and some of that is
addons enabled in this very build — Container Insights and the Key Vault CSI driver each bring
their own pods. The lesson is the one D8 already records, learned more thoroughly than intended:
measure the cluster, do not estimate it.

## Harness findings

Things about the test tooling, not the service, that would otherwise have been reported as
service behaviour.

- **`kubectl port-forward svc/...` does not load-balance.** It resolves the Service to one pod
  and pins every request to it: the two API pods ran at 41m and 3m of CPU. It also adds large
  latency under load, and it dies when its pinned pod is evicted. Experiment 4 used
  `kubectl proxy` through the Service instead, which follows endpoints.
- **Git Bash rewrote a Helm value.** `chaosDaemon.socketPath=/run/containerd/containerd.sock`
  became `C:/Program Files/Git/run/containerd`, and the Chaos Mesh daemon failed to start on both
  nodes. Fixed with `MSYS_NO_PATHCONV=1`.
- **A mutable image tag would not have redeployed.** `:dev` defaults to
  `imagePullPolicy: IfNotPresent`, so nodes would have kept the cached old image. The fixes were
  deployed by git SHA instead.

## Open items

| Finding | From | Status |
|---------|------|--------|
| Jobs lost when a worker pod dies | Exp 1 | **Fixed** — leased fetch; verified locally, not yet on a cluster |
| SLI blind to failures that never reach the app | Exp 2 | **Open** — needs edge or synthetic measurement |
| System pod replicas co-located on one node | Exp 4 | **Open** — topology spread or descheduler |
| HTTP latency histogram too coarse above 1s | Exp 3 | **Open** |
| Readiness `timeoutSeconds` headroom | Exp 3 | Fixed; not re-verified on a cluster |
| First outage invisible to the SLI | Exp 2 | **Fixed and re-verified** |
| Readiness flapping under dependency latency | Exp 3 | **Fixed and re-verified** |
