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

Two Standard_B2s nodes are 4 vCPUs raw, roughly 3.0 allocatable once AKS takes its reservations,
and roughly 2.6 usable after system pods. One node alone offers about 1.1 usable.

Worker CPU requests are therefore **150m in production, not 200m**, and KEDA's ceiling is
**8 replicas**:

| Workers | CPU requested | Fits on one node? |
|---------|---------------|-------------------|
| at rest (2) | 0.47 | yes |
| 4 | 0.77 | yes |
| 6 | 1.07 | marginal |
| **8** | **1.37** | **no — a second node is required** |

That is the whole point. At 8 workers the scheduler genuinely cannot place the pods on one node,
so the cluster autoscaler has to add the second — a real demonstration rather than a staged one —
while the total stays well inside the two-node cap.

At 200m per worker the same experiment would have hit the vCPU quota instead of the autoscaler,
and the failure would have looked like KEDA being broken rather than the subscription being
small. Sizing to the constraint is what makes the result mean something.

A second consequence worth knowing before it bites: AKS needs at least one surge node during a
node pool upgrade, so with two nodes running at the cap, an upgrade will be refused for lack of
capacity. Scale down to one node first, or raise the quota.

**Note.** The subscription also has `spendingLimit: On`. When the credit is exhausted the
subscription is disabled rather than charged. That is the desired behaviour for a learning
project and should be left alone.
