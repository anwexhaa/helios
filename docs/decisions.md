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
