# Alerting

Every alert in this repo answers one question: **would a user notice?** If the answer is no, it
is a dashboard panel, not an alert.

---

## Symptoms, not causes

The instinct when setting up monitoring is to alert on the things that are easy to measure — CPU,
memory, restart counts, disk. None of those are in `prometheus-rules.yaml`, and the omission is
deliberate.

**High CPU is not an incident.** A pod at 95% CPU that is serving every request inside its
latency objective is a pod doing its job efficiently. Paging for it trains whoever is on call to
dismiss alerts, which is the most expensive thing monitoring can do to a team.

**A pod restart is not an incident.** The worker pool is *designed* to replace stalled workers.
A restart that costs no user-visible latency is the system working as intended.
`orion_workers_replaced_total` is on the dashboard so churn is visible, but it does not page.

**A deep queue is not an incident.** Bursts are normal and the autoscaler exists to absorb them.
What matters is whether jobs are dispatched within the objective, which the latency SLI already
measures.

The rule this follows: alert on a cause only once you have watched that cause hurt a user, and
then prefer to alert on the hurt.

---

## The two severities

| Severity | Means | Delivery |
|----------|-------|----------|
| `page` | Users are being harmed now and it will not fix itself | Wakes a human |
| `ticket` | Real, needs a person, does not need one immediately | Queued for working hours |

Nothing else. A third level in the middle always collapses into "ignore".

---

## Why burn rate rather than a threshold

The obvious availability alert is "error rate above 1%". It fails in both directions.

A one-minute blip above 1% pages someone about an incident that is already over. Meanwhile a
sustained 0.9% error rate never fires at all, while quietly exhausting a month of error budget.
Neither behaviour tracks whether the promise to users is actually being kept.

Burn rate does. It asks: *at this rate, how long until the budget is gone?* That is the question
worth waking someone for, and it scales automatically — the same alert works whether the service
gets ten requests a minute or ten thousand.

The thresholds and the arithmetic behind them are in [slo.md](slo.md).

---

## Why each alert has two windows

```
fast burn = 1h burn rate > 13.44  AND  5m burn rate > 13.44
```

The long window establishes that the problem is real and sustained. The short window is what
lets the alert **resolve**.

Without it: a five-minute total outage leaves the 1h burn rate elevated for a full hour
afterwards, so the alert keeps firing for 55 minutes after the service recovered. Whoever is on
call learns that the alert does not correspond to reality, and starts waiting for it to clear on
its own. The alert has then stopped working, regardless of whether it is technically correct.

---

## Prometheus and Azure Monitor do different jobs

Both are used, and the split is not arbitrary:

| | Measures | Examples |
|---|---|---|
| **Prometheus** | The service | Error budget burn, dispatch latency, queue stalled, Redis unreachable |
| **Azure Monitor** | The platform underneath it | Node not ready, disk pressure, cluster autoscaler failing to scale |

Prometheus runs *inside* the cluster, which means it cannot tell you about a cluster that is
gone. That is exactly when Azure Monitor matters — and exactly why the infrastructure alerts do
not live in Prometheus.

The corollary: a Prometheus alert going silent is itself a signal. If `orion_redis_up` stops
being reported, that is not Redis being healthy.

---

## No-traffic handling

Every SLI expression divides by a request rate. With no traffic the denominator is zero and the
result is `NaN`, and every comparison against `NaN` is false.

So alerts stay silent on an idle service rather than firing spuriously or reporting a false
100%. This is the correct behaviour and it is worth knowing about, because "the alert did not
fire" and "there was nothing to measure" look identical on a dashboard.

The dev and test environments are not alerted on at all, for the same reason in a different
form: an objective on an environment nobody depends on measures nothing.

---

## Every alert must have a runbook

`runbook_url` is required on every alert that pages. An alert that fires at 3am with no
instructions is a puzzle, not a signal, and the person solving it is doing so under the worst
possible conditions.

The runbooks live in [`runbooks/`](../runbooks/) and are exercised during Phase 4 game days — an
untested runbook is a guess written down.
