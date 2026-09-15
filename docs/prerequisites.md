# Phase 0 — Ground work

Everything that has to exist before Phase 1 can provision anything.

## Accounts

| Item | Status | Notes |
|------|--------|-------|
| Azure subscription | Pending | Azure for Students gives $100 with no card if the college email qualifies; otherwise the 30-day $200 free trial |
| Azure DevOps organisation | Pending | Needed in Phase 2, but create it now |
| Free parallel-jobs grant | Pending | **Submit first.** Approval takes about two business days and blocks Phase 2 |
| Budget alert at ₹2,000 | Pending | Subscription-level, so a forgotten cluster cannot drain the credit |

The parallel-jobs grant is the only item in this plan with a queue in front of it. Private
Azure DevOps projects get no hosted parallelism by default; the request form restores one free
Microsoft-hosted job with 1,800 minutes a month. Public projects are granted it automatically.

## Toolchain

Verified on Windows 11 with `make preflight`.

| Tool | Status | Install |
|------|--------|---------|
| git | 2.53.0 | installed |
| docker | 29.2.1 | installed |
| kubectl | 1.34.1 | ships with Docker Desktop |
| python | 3.12.10 | installed |
| az | 2.90.0 | installed |
| terraform | 1.16.2 | installed |
| helm | 4.3.0 | installed |
| k6 | missing (Phase 4) | `winget install Grafana.k6` |

Open a new shell after installing so the updated `PATH` is picked up, then:

```bash
make preflight
```

It exits non-zero until every required tool is present and `az account show` succeeds, so it
can gate the rest of the Makefile.

## Azure quota

Student subscriptions carry a low default vCPU quota per region. Check it before choosing VM
sizes in Phase 1 — the node pool is 2 vCPUs per B2s, and the cluster autoscaler is allowed to
reach three nodes:

```bash
az vm list-usage --location centralindia --output table | grep -i "Total Regional vCPUs"
```

If the limit is below 8, either request an increase or lower `max_count` on the node pool.

## Container image

Orion Queue must build and run outside its compose file before the cluster ever sees it:

```bash
docker build -t orion-queue:local .
docker run --rm -p 8000:8000 orion-queue:local
curl localhost:8000/health
```

A container that only works under `docker compose` usually has a hostname or an environment
variable baked into it that Kubernetes will not supply. Find that now, not in Phase 1.

## Definition of done

- `az account show` returns your own subscription
- The Azure DevOps parallel-jobs request is submitted
- `make preflight` passes
- The Orion Queue image runs standalone and answers `/health`
