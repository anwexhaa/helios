# Service level objectives

What "working" means for Orion Queue, stated precisely enough to be measured and alerted on.

Two indicators. Both are computed from metrics the service already exposes, over a **28-day
rolling window**, against the **production** environment only. Dev and test are not measured —
an SLO on an environment nobody depends on is theatre.

---

## SLI 1 — Availability

**The proportion of HTTP requests that the service answered without failing.**

```promql
sum(rate(orion_http_requests_total{status=~"5.."}[28d]))
  /
sum(rate(orion_http_requests_total[28d]))
```

Three decisions are buried in that expression, and each one changes what the number means.

**Only 5xx counts as a failure.** A `404` from `/status/{job_id}` is the service working
correctly — it was asked about a job that does not exist and said so. Counting 4xx would let a
client with a broken retry loop burn a budget that exists to measure *our* reliability.

**Probe and scrape traffic is excluded**, at the source. The kubelet hits `/health` and `/ready`
every few seconds; Prometheus scrapes `/metrics` on its own interval. Those requests outnumber
real traffic by orders of magnitude and essentially always succeed, so including them would pin
the SLI near 100% while every user request failed. The exclusion list lives in `api.py` as
`SLI_EXCLUDED_ROUTES`.

**No traffic means no SLI, not a perfect one.** With a zero denominator the ratio is `NaN`, and
every comparison against `NaN` is false, so alerts stay silent rather than firing or reporting
success. That is the correct behaviour: an idle service has not proved anything either way.

### Target

**99.5%** over 28 days.

Chosen to be honest rather than impressive. The cluster is two burstable nodes with no
cross-zone redundancy on a free-trial subscription; 99.9% would be missed most weeks, and a
target missed routinely stops meaning anything. 99.5% leaves a budget large enough that a single
chaos experiment visibly moves it — which is the entire point of measuring.

### Error budget

28 days is 40,320 minutes. The budget is the share of that the service may be failing:

| Target | Budget per 28 days | Verdict here |
|--------|--------------------|--------------|
| 99.0% | 6 h 43 m | too loose to be interesting |
| **99.5%** | **3 h 21 m 36 s** | **chosen** |
| 99.9% | 40 m 19 s | dishonest on this infrastructure |
| 99.95% | 20 m 10 s | would never be met |

---

## SLI 2 — Latency

**The proportion of jobs dispatched to a worker within 300 ms of submission.**

```promql
sum(rate(orion_dispatch_latency_seconds_bucket{le="0.3"}[28d]))
  /
sum(rate(orion_dispatch_latency_seconds_count[28d]))
```

**Target: 95%.**

This measures queue wait, not execution time — the part the service controls. How long a task
takes to run is the task author's business; how long it sits unclaimed is ours.

`0.3` must exist as a bucket boundary in `DISPATCH_BUCKETS` or this number becomes an
interpolation between whatever boundaries do exist. It is there deliberately, with a comment
saying so. **Changing the latency target means changing the buckets**, and a histogram's
buckets cannot be changed retroactively — old data keeps the old boundaries.

Only the first attempt of a job is measured. A retried job keeps its original `submit_time`, so
including retries would fold deliberate backoff delay into the latency SLI and make the service
look slowest exactly when its retry logic is working correctly.

---

## Burn rate

A burn rate of 1 means the budget is being consumed exactly fast enough to exhaust it at the end
of the window. A burn rate of 14 means it will be gone in about two days.

For a 28-day window (672 hours), the burn rate that consumes a given share of budget in a given
time is:

```
burn_rate = budget_fraction_consumed x 672 / window_hours
```

| Alert | Consumes | In | Burn rate | Error ratio at 99.5% |
|-------|----------|-----|-----------|----------------------|
| **Fast burn** — page | 2% of budget | 1 hour | **13.44x** | 6.72% |
| **Slow burn** — ticket | 5% of budget | 6 hours | **5.6x** | 2.8% |

These are the canonical Google SRE thresholds recalculated for a 28-day window rather than the
30-day one they are usually quoted for. Using 14.4 and 6 unmodified would be *approximately*
right and quietly wrong, and the difference compounds across a month.

### Why two windows per alert

Each alert requires both a **long** window and a **short** one to be burning:

```
fast burn  =  1h burn rate > 13.44  AND  5m burn rate > 13.44
slow burn  =  6h burn rate > 5.6    AND  30m burn rate > 5.6
```

The long window is what makes the alert meaningful — a genuine problem sustained long enough to
matter. The short window is what makes it *stop*: without it, a five-minute outage keeps the 1h
burn rate elevated for a full hour, and the alert keeps paging long after the service recovered.
Alerts that continue firing after the incident ends are the fastest route to alerts being
ignored.

---

## What is deliberately not an SLO

**Queue depth.** A deep queue is not by itself a failure — a burst of work is normal, and the
autoscaler exists to absorb it. What matters is whether jobs are being dispatched within the
latency objective, which SLI 2 already captures. Queue depth is a useful *diagnostic* and a
scaling signal, not a promise to anyone.

**Worker restarts.** The pool is designed to replace stalled workers; doing so is the system
working. `orion_workers_replaced_total` is worth a dashboard panel so that churn is visible, but
a restart that costs no user-visible latency has not broken a promise.

**CPU and memory.** Symptoms of nothing on their own. See `alerting.md`.
