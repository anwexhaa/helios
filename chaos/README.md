# chaos

Four experiments, each a hypothesis about how the system behaves under a specific failure.

An experiment without a written hypothesis is not an experiment — it is breaking something and
seeing what happens. The difference matters, because only the first one can be wrong in a way
you learn from.

| # | Experiment | Hypothesis in one line |
|---|-----------|------------------------|
| 1 | [Worker pod killed](01-worker-pod-kill.yaml) | The pool absorbs it with no user-visible cost |
| 2 | [Redis killed](02-redis-pod-kill.yaml) | Degrades cleanly and fast, rather than hanging |
| 3 | [Redis +500ms](03-redis-latency.yaml) | Latency objective breaks while everything looks healthy |
| 4 | [Node drained](04-node-drain.md) | Pods reschedule; the PDB protects availability |

## Before running any of them

Install Chaos Mesh:

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-testing --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock
```

`chaosDaemon.runtime=containerd` is required on AKS. The chart defaults to Docker, which AKS has
not used since Kubernetes 1.19 — with the default, the daemon starts, reports healthy, and
silently cannot inject anything.

## Running one

Each experiment is a game day, not a `kubectl apply`. Before starting:

1. Write the hypothesis down and the time you started.
2. Have the relevant runbook open — the point is to exercise it, not to read it afterwards.
3. Have the Grafana SLO dashboard open, and note the error budget *before*.

Then apply the manifest, and record: detection time, recovery time, budget consumed, and
whether the runbook was correct.

Results go in [`docs/gamedays.md`](../docs/gamedays.md). An experiment that was run and not
recorded has cost error budget and produced nothing.

## Cleaning up

```bash
kubectl -n helios-prod delete podchaos --all
kubectl -n helios-prod delete networkchaos --all
```

Experiment 3 has a `duration` and reverts on its own. Experiments 1 and 2 are one-shot kills
with nothing to revert. Experiment 4 needs an explicit `kubectl uncordon`.
