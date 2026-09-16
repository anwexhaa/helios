# Decisions

Short records of the choices that shape the build, kept so the reasoning survives the project.

---

## D1 — Run an existing service rather than write a new one

**Decision.** Helios deploys and operates Orion Queue. It does not introduce new application code.

**Why.** The interesting work here is operational, not functional. Writing another CRUD app
would consume the build time and produce service level indicators nobody cares about. A task
queue already exposes the two signals worth alerting on — queue depth and dispatch latency —
and keeping someone else's service alive is the actual job being applied for.

**Consequence.** Application changes stay minimal and are limited to what operability requires:
a `/health` endpoint, a Prometheus `/metrics` endpoint, and honest resource requests.

---

## D2 — Terraform, not Bicep

**Decision.** The Azure environment is described in Terraform.

**Why.** Bicep is already demonstrated on another project, so Terraform adds a second
infrastructure-as-code tool rather than repeating the first. It is also the more common choice
on consulting engagements, which is where this work is headed.

**Trade-off.** Bicep has tighter same-day support for new Azure resource types. Nothing in this
build needs a resource that recent.

---

## D3 — Availability target of 99.5%

**Decision.** 99.5% availability over a rolling 28 days. Error budget: 3 h 21 m.

**Why.** On two burstable B2s nodes with no redundancy across zones, 99.9% would be a number
quietly missed every week, and a target you always miss teaches nothing. 99.5% leaves a budget
large enough that a single chaos experiment visibly moves it, which is the point of measuring.

**Consequence.** Burn-rate alert thresholds derive from 0.005 as the budget fraction. If the
target changes, every alert expression changes with it.

---

## D4 — Self-hosted Prometheus and Grafana

**Decision.** `kube-prometheus-stack` runs in the cluster. Azure Managed Grafana is not used.

**Why.** Managed Grafana bills per month regardless of use; the in-cluster stack costs only the
node capacity already paid for, and it disappears with `make down` like everything else.

**Trade-off.** Dashboards die with the cluster, so they are exported as JSON into the repo and
reapplied on provision. That is the desired behaviour anyway — see working rule 1.

**Note.** Azure Monitor and Log Analytics are still used, for infrastructure-level alerts and
KQL log triage. The two are complementary: Prometheus measures the service, Azure Monitor
measures the platform under it.

---

## D5 — Scale workers on queue depth, not CPU

**Decision.** KEDA scales the worker deployment on Redis list length. The HPA on the API uses
request rate.

**Why.** A worker blocked on I/O shows low CPU while the backlog grows, so CPU-based scaling
reacts late or not at all. Queue depth is the signal that actually correlates with user-visible
delay.

**Consequence.** KEDA becomes a cluster dependency, and the Redis connection it uses needs its
own credentials and network path.

---

## D6 — The KEDA `redis` scaler cannot be used

**Decision.** Worker autoscaling uses KEDA's `metrics-api` scaler, moving to the `prometheus`
scaler once Phase 3 is in place. The `redis` scaler is not an option.

**Why.** `priority_queue.py` stores jobs in a Redis sorted set — `zadd`, `zpopmax`, `zcard` on
the key `task_queue`, scored by priority. KEDA's `redis` scaler measures list length with
`LLEN`, which returns zero against a sorted set. It would never scale, and it would never error
either, which is worse.

Converting the queue to a list would fix the scaler and destroy the priority ordering that is
the substance of the service. The scaler changes, not the queue.

**Consequence.** Worker autoscaling depends on the service exposing queue depth over HTTP.
Until then, KEDA has nothing to read. See [F6 in the production readiness review](production-readiness-review.md).

**Supersedes.** The original plan specified `type: redis` with `listName`. That configuration is
wrong for this service.

---

## D7 — One autoscaling node pool, not a system and user pool split

**Decision.** The cluster runs a single node pool, autoscaling from 1 to 3 nodes, rather than a
fixed system pool plus a separate autoscaling user pool.

**Why.** Two pools means at least two nodes running at all times. On Standard_B2s that roughly
doubles the daily cost, for a cluster with one workload on it and no noisy-neighbour problem to
solve. The cluster autoscaler behaviour that Phase 4 needs to demonstrate works identically with
one pool.

**Trade-off.** In production, isolating system pods from application pods is correct — a
workload that exhausts a node should not take CoreDNS or the metrics server with it. That
separation is deliberately traded away here for cost, which is the honest reason, and the right
answer to give if asked about it in an interview.

**Consequence.** Application pods and system pods are scheduled together. If a chaos experiment
in Phase 4 destabilises the node, expect cluster components to wobble too. Note it in the game
day record rather than treating it as a surprise.

---

## D8 — The node pool tops out at two nodes, because the subscription is a free trial

**Decision.** `node_max_count` defaults to 2, not 3.

**Why.** The subscription's `quotaId` is `FreeTrial_2014-09-01`, which carries a hard limit of
**4 regional vCPUs** in every region. Standard_B2s is 2 vCPUs, so two nodes is exactly the cap
and three is impossible. Unlike pay-as-you-go quota, this one is not raised on request —
Microsoft does not grant increases on free trial subscriptions. Upgrading to pay-as-you-go is
the only route to more.

This was found by querying `az vm list-usage` before the first apply rather than by watching
the apply fail, which is the difference between a constraint and an incident.

**Consequence.** The cluster autoscaler can still be demonstrated — it scales 1 to 2 nodes, and
the mechanism is identical. Phase 4 is sized to fit rather than the subscription being upgraded;
that choice is deliberate and final.

### Phase 4 sizing, derived rather than guessed

**Measured on the running cluster**, not estimated: a Standard_B2s_v2 node reports **1900m
allocatable CPU** and 6.6 GiB allocatable memory. Two nodes is therefore 3.8 vCPU allocatable,
better than the 3.0 originally assumed here. The dev deployment actually requests 220m, leaving
1.68 vCPU of headroom on a single node.

Worker CPU requests are therefore **150m in production, not 200m**, and KEDA's ceiling is
**8 replicas**:

| Workers | CPU requested | Fits on one node? |
|---------|---------------|-------------------|
| at rest (2) | 0.47 | yes |
| 4 | 0.77 | yes |
| 6 | 1.07 | marginal |
| **8** | **1.37** | **yes on 1.9 allocatable — see below** |

**Revised once the node was measured.** At 1900m allocatable rather than the assumed 1500m, 8
workers at 150m (1.37 vCPU total) still fit on a single node once system pods are accounted for,
so this would not force a second node after all. Phase 4 needs either a higher KEDA ceiling or
larger worker requests to make the cluster autoscaler actually engage — the exact figure to be
fixed by measuring real system pod usage under load, not by guessing again.

The lesson stands either way: size the experiment so the autoscaler is what responds, and verify
against the real cluster rather than an estimate.

At 200m per worker the same experiment would have hit the vCPU quota instead of the autoscaler,
and the failure would have looked like KEDA being broken rather than the subscription being
small. Sizing to the constraint is what makes the result mean something.

A second consequence worth knowing before it bites: AKS needs at least one surge node during a
node pool upgrade, so with two nodes running at the cap, an upgrade will be refused for lack of
capacity. Scale down to one node first, or raise the quota.

**Note.** The subscription also has `spendingLimit: On`. When the credit is exhausted the
subscription is disabled rather than charged. That is the desired behaviour for a learning
project and should be left alone.

---

## D9 — Standard_B2s_v2, because the v1 B-series is not offered here

**Decision.** The node pool runs `Standard_B2s_v2`.

**Why.** `Standard_B2s` was rejected outright by AKS:

> The VM size of Standard_B2s is not allowed in your subscription in location 'centralindia'.

Not a quota problem — the SKU simply is not offered to this subscription in this region. The v1
B-series has been superseded by Bsv2 nearly everywhere.

`Standard_B2s_v2` is the same 2 vCPUs, so it costs exactly the same against the 4 vCPU cap, and
carries **8 GiB of memory rather than 4**. Its quota lives in a separate bucket, `Standard Bsv2
Family vCPUs`, which is also 4. Strictly better for the same price.

**Consequence.** Twice the memory per node, so the memory side of the Phase 4 sizing has more
headroom than D8 assumed. The CPU arithmetic in D8 is unchanged and remains the binding
constraint.

**Watch out.** B2s_v2 carries a *zone* restriction in centralindia: zones 1 and 3 are closed to
this subscription, zone 2 is open. The node pool is deliberately non-zonal, so this does not
apply — but adding `zones` to `default_node_pool` would reintroduce it, and the failure would
appear at apply time as a capacity error rather than anything obviously zone-related.

**How this was found.** By reading the error, then querying `az vm list-skus` for the
restriction *type* rather than assuming the region was unavailable. The distinction between a
Zone restriction and a Location restriction is the difference between changing one variable and
moving the whole build to another region.

---

## D10 — KEDA reads the application, not Prometheus

**Decision.** The worker ScaledObject uses the `metrics-api` scaler against the service's own
`/stats` endpoint. It does not use the `prometheus` scaler, even though Phase 3 now makes that
possible.

**Why.** D6 ruled out the `redis` scaler because the queue is a sorted set and that scaler reads
`LLEN`. It then said to prefer the `prometheus` scaler once Phase 3 existed, on the grounds that
scaling on the same number the SLO dashboard shows is tidier.

That reasoning was about neatness, and it is wrong on reliability grounds. The `prometheus`
scaler makes worker scaling depend on the monitoring stack being healthy. If Prometheus falls
over while the queue is backing up — and Prometheus is the component most likely to be evicted
under memory pressure on a two-node cluster — scaling stops at exactly the moment it is needed,
and the queue grows unattended.

**The principle.** A control loop should not depend on the observability stack. Monitoring
watches the system; it should not be load-bearing *inside* it. `/stats` is served by the API
itself: if that is down, scaling workers would not have helped anyway.

**Trade-off.** Scaling now reads a number that does not pass through Prometheus, so a
discrepancy between the dashboard and the scaler's view is possible. Both ultimately read
`ZCARD` on the same key, so a divergence means one of them is stale rather than wrong.

**Supersedes.** D6's preference for the `prometheus` scaler. The rejection of the `redis` scaler
still stands.

---

## D11 — The API scales on CPU and the workers do not

**Decision.** `orion-worker` scales on queue depth (D5). `orion-api` scales on CPU utilisation.

**Why.** This looks like a contradiction and is not: the two components degrade differently.

A worker spends nearly all its time blocked — on Redis, and on whatever the task does. Its CPU
stays low while the backlog grows, so CPU-based scaling reacts late or never. Queue depth is the
signal that correlates with user-visible delay.

The API is request-driven and does its work in-process: parse, serialise, one Redis round trip,
respond. CPU does track offered load there, and the thing that degrades is request latency,
which CPU predicts reasonably.

**Trade-off.** Scaling the API on request rate would be marginally better, but it needs a custom
metrics adapter — another controller to install, understand and keep running — for a component
that is not the bottleneck on this workload. The honest reason is cost, recorded rather than
dressed up.
