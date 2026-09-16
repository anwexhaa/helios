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
| make | **missing** | `winget install -e --id ezwinports.make` |
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

**Run `make` from Git Bash, not PowerShell.** The Makefile sets `SHELL := /bin/bash` and its
recipes are POSIX shell; PowerShell cannot resolve `/bin/bash`. Every target also has a plain
equivalent — `make preflight` is just `./scripts/preflight.sh` — so nothing here is locked
behind `make` if you would rather not install it.

It exits non-zero until every required tool is present and `az account show` succeeds, so it
can gate the rest of the Makefile.

## Azure quota — measured, not assumed

This subscription is an Azure **free trial** (`quotaId: FreeTrial_2014-09-01`), which carries a
hard cap of **4 regional vCPUs**. Microsoft does not raise quota on free trial subscriptions;
upgrading to pay-as-you-go is the only route to more.

| Quota | Limit |
|-------|-------|
| Total Regional vCPUs (centralindia) | 4 |
| Standard BS Family vCPUs | 4 |

Standard_B2s is 2 vCPUs, so the node pool tops out at **two nodes**. `node_max_count` is set to
2 accordingly. Recorded as decision D8.

Re-check any time with:

```bash
az vm list-usage --location centralindia --output table
```

## Resource providers

A new subscription has no resource providers registered, and `az vm list-usage` returns an empty
list until `Microsoft.Compute` is. Terraform would fail partway through the first apply.
Registered up front:

```bash
for p in Microsoft.Compute Microsoft.ContainerService Microsoft.ContainerRegistry          Microsoft.Network Microsoft.Storage Microsoft.OperationalInsights          Microsoft.KeyVault Microsoft.ManagedIdentity; do
  az provider register --namespace "$p"
done
```

Registration is asynchronous and took about 30 seconds for all of them.

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
