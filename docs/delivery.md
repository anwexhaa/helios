# Delivery

How a commit reaches production.

```
commit to main
      │
      ▼
  verify ──── pytest against a real Redis
      │       az acr build  →  image tagged with the git SHA
      │       trivy scan, HIGH/CRITICAL fails the run
      ▼
  deploy_dev ──── apply → wait for rollout → smoke test
      │                                          │ fails → rollout undo
      ▼
  deploy_test ─── same steps, helios-test
      │
      ▼
  [ manual approval ]          ← the only human step
      │
      ▼
  deploy_prod ─── same steps, helios-prod
```

Every environment runs identical steps. The only differences are the namespace and the
kustomize overlay. If dev deployed differently from prod, a green dev would prove nothing.

## The image tag is the git SHA

Never `latest`. A pod running `orion-queue:latest` cannot be traced to the source that built
it, and two pods carrying that tag may be running different code. `kustomize edit set image`
pins the exact digest-bearing tag this run produced, in the overlay, at deploy time.

## Why the smoke test exists

A rollout reporting `Ready` means containers started and their probes passed. It does not mean
the service works.

The failure that proves the point: stop the worker deployment and leave the API running. Every
probe stays green — the API is genuinely healthy, it accepts jobs, it returns 200 on `/health`
and `/ready` — and not a single job is ever executed. Kubernetes calls that deploy a success.

So the smoke test submits a real job and waits for it to reach `done`:

```
  ok    /health returned 200
  ok    /ready returned 200
  ok    /metrics serves Prometheus exposition format
  ok    POST /submit accepted a job
  FAIL  job never left pending within 12s — workers may not be consuming
```

That is the signal the pipeline rolls back on, and it is the only check in the set that would
have caught it.

## Rollback

The rollback step is `condition: failed()` on the same job as the smoke test, so it runs in the
environment that just broke, not as a separate stage someone has to trigger. It runs
`kubectl rollout undo` on all three deployments and then fails the stage, so a rolled-back
deploy still shows red. A silent rollback is worse than no rollback: the cluster is fine and
nobody knows the release did not land.

Rolling back by hand, if the pipeline itself is unavailable:

```bash
kubectl -n helios-prod rollout undo deploy/orion-api
kubectl -n helios-prod rollout undo deploy/orion-worker
kubectl -n helios-prod rollout undo deploy/orion-scheduler
kubectl -n helios-prod rollout status deploy/orion-api
```

## Who approves production

The approval check lives on the `helios-prod` Environment in Azure DevOps, not in the pipeline
YAML. That is deliberate: an approval defined in the YAML can be removed by editing the YAML,
which is exactly the file a change is trying to ship. Environment checks are configured
separately and cannot be bypassed by the pipeline that they gate.

Currently the sole approver is the repository owner. In a team this would be anyone on the
on-call rotation other than the change author.

## What has to exist in Azure DevOps first

| Item | Notes |
|------|-------|
| GitHub service connection `github-anwexhaa` | Lets the pipeline check out orion-queue |
| Azure Resource Manager service connection | Workload identity federation, **not** a client secret |
| Environments `helios-dev`, `helios-test`, `helios-prod` | Approval check on prod only |
| Variable group `helios` | `acrName`, `acrLoginServer`, `resourceGroup`, `clusterName`, `azureServiceConnection` |
| Free parallel-jobs grant | Private projects get no hosted parallelism by default |

## Status

The pipeline YAML and the smoke test are written. The smoke test is verified — it passes
against a healthy stack, fails when nothing is listening, and fails specifically on a stalled
worker pool while every probe still reports healthy.

The pipeline itself has never run. It cannot until the Azure DevOps organisation, the service
connections and the cluster exist. Treat the first run as a debugging session rather than a
deployment, and run it against dev only.
