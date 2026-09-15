# Helios

An SLO-driven reliability platform on Azure Kubernetes Service.

Helios does not introduce a new application. It takes an existing service —
[Orion Queue](https://github.com/anwexhaa), a Python/Redis distributed task queue — and runs it
the way a site reliability engineer runs a service: provisioned by Terraform, shipped by a gated
pipeline, measured against an error budget, and deliberately broken until it heals itself.

The platform is the project.

## Build phases

| Phase | Scope | Status |
|-------|-------|--------|
| 0 | Ground work — accounts, toolchain, repo scaffold | Done |
| 1 | Cluster and infrastructure as code | Terraform and manifests written, not yet applied |
| 2 | Multi-environment delivery pipeline | Not started |
| 3 | Observability, SLOs and alerting | Not started |
| 4 | Autoscaling, chaos and incident response | Not started |

## Layout

```
infra/       Terraform — the entire Azure environment (Phase 1)
k8s/         Kubernetes manifests; base plus one overlay per environment
pipelines/   Azure DevOps multi-stage pipeline definitions (Phase 2)
scripts/     preflight, smoke tests, load generation
runbooks/    One page per failure mode (Phase 4)
docs/        SLO definitions, alerting policy, game days, postmortems
docs/kql/    Saved Log Analytics triage queries (Phase 3)
```

## Service level objectives

Measured over a rolling 28 days, against the production environment only.

| Indicator | Definition | Target | Error budget |
|-----------|-----------|--------|--------------|
| Availability | successful requests / total requests | 99.5% | 3 h 21 m per 28 days |
| Latency | share of jobs dispatched within 300 ms | 95% | — |

Full definitions land in `docs/slo.md` in Phase 3.

## Running it

```bash
make preflight   # verify the local toolchain and Azure sign-in
make bootstrap   # create the Terraform state account, once per subscription
make init        # initialise Terraform against that backend
make up          # provision everything
make down        # destroy everything
```

`make help` lists every target.

## The service being operated

Orion Queue is not modified by this repo; Helios deploys it. A production readiness review was
carried out before any infrastructure was provisioned. It found eight issues, all now fixed on
the `feat/kubernetes-readiness` branch of orion-queue — including a heartbeat monitor that
would have crashed the first time a worker actually stalled, taking the service's self-healing
with it.

See [docs/production-readiness-review.md](docs/production-readiness-review.md).

## Cost

The cluster runs on burstable B2s nodes and costs roughly ₹80–120 per day while it is up.
The AKS control plane itself is free; the node pool, the Log Analytics workspace and the
container registry are not.

**Destroy the cluster when you stop for the day.** The Terraform is the artifact, not the
running cluster. `make down` should be the last command of every session.

A budget alert is configured on the subscription so a forgotten cluster cannot quietly drain
the credit.

## Working rules

1. **If it is not in the repo, it did not happen.** Terraform, manifests, pipeline YAML,
   dashboards exported as JSON, runbooks.
2. **Destroy the cluster nightly.** Rebuilding it every session is free practice.
3. **Record every number the moment you measure it.** Reconstructed numbers are guesses.
4. **Never alert on a cause you have not watched hurt a user.** High CPU is not an incident.
   A queue nobody is draining is.
