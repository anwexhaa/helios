# Experiment 4 - drain a node

Not a Chaos Mesh manifest. Chaos Mesh has no node-drain action, and faking it by killing every
pod on a node would test something different: a drain is *graceful*, and the graceful path is
exactly what is in question.

## Hypothesis

Every pod on the drained node is evicted and rescheduled onto the other node. The
PodDisruptionBudget keeps at least one API pod available throughout, so no request is refused.
Workers drain on SIGTERM and finish their in-flight jobs rather than dropping them.

## Why this one is the most likely to fail

The cluster is two nodes at a 4 vCPU cap. Draining one leaves a single node to hold everything:
the application, the monitoring stack, and the AKS system pods. If the remaining node cannot fit
it all, pods sit Pending and the experiment shows a capacity problem rather than a resilience
one — which is still worth knowing, and is the honest consequence of decision D8.

## Procedure

```bash
# Pick the node NOT running the most pods, so the test is meaningful
kubectl get pods -A -o wide | awk '{print $8}' | sort | uniq -c
NODE=<node-name>

# Start the clock
date +%s

kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s
```

Watch, in another terminal:

```bash
kubectl get pods -A -o wide -w
kubectl -n helios-prod get pdb orion-api -w
```

## Recovery

```bash
kubectl uncordon "$NODE"
```

The cluster autoscaler will not add a node to replace a cordoned one — it is still there, just
unschedulable. Uncordon is the whole recovery.

## Record

Time to reschedule, whether any pod stayed Pending, whether the PDB ever blocked an eviction,
and whether the smoke test passed throughout. A drain that succeeds while the smoke test fails
is a drain that lost work.
