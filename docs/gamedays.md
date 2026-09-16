# Game days

Results from the chaos experiments in [`chaos/`](../chaos/).

Every row here costs real error budget. An experiment that was run and not written up spent that
budget for nothing.

## Results

**Not yet run.** The cluster is destroyed between sessions and these need it up, with the
monitoring stack installed, for long enough to observe an alert fire.

| # | Experiment | Detected in | Recovered in | Budget burned | Runbook correct? |
|---|-----------|-------------|--------------|---------------|------------------|
| 1 | Worker pod killed | — | — | — | — |
| 2 | Redis killed | — | — | — | — |
| 3 | Redis +500ms | — | — | — | — |
| 4 | Node drained | — | — | — | — |

**Detected in** — from injecting the fault to the alert arriving. Not to noticing it on a
dashboard you were already staring at; that is not detection.

**Recovered in** — to the smoke test passing again, not to the pod showing Ready. Those are
different, and the gap between them is the interesting part.

**Runbook correct?** — did the runbook's diagnosis steps actually lead to the cause. A runbook
that was wrong is the most valuable output of a game day.

## How to run one

```bash
# 1. Baseline: note the error budget and pod counts
kubectl -n helios-prod get pods
# open Grafana, record job:slo_error_budget_remaining:ratio

# 2. Start load, so the failure has traffic to affect
cd scripts/loadtest && k6 run -e BASE_URL=... -e RATE=25 -e DURATION=10m submit.js

# 3. Note the time, inject the fault
date +%s; kubectl apply -f chaos/01-worker-pod-kill.yaml

# 4. Wait for the alert. Do not fix it early - the detection time is the measurement

# 5. Follow the runbook. Record where it was wrong

# 6. Confirm recovery with the smoke test, not with pod status
./scripts/smoke.sh http://localhost:18080
```

## Findings

Weaknesses these experiments exposed, and what was done about them.

*None recorded yet.*

Two are expected, and predicting them is part of the exercise:

- **Experiment 3 should break the latency objective while every probe stays green.** If it does
  not, either the delay is not being injected or the latency SLI is not measuring what it
  claims to.
- **Experiment 4 may leave pods Pending** rather than rescheduling, because one node has to hold
  everything on a 4 vCPU cap. That would be a capacity finding, not a resilience one — and a
  direct consequence of D8.

If an experiment produces exactly what was predicted and nothing else, say so. A game day that
confirms the hypothesis is a good outcome; a game day written up as more dramatic than it was is
worse than not running it.
