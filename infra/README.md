# infra

Terraform describing the entire Azure environment.

| File | Contents |
|------|----------|
| `versions.tf` | Provider pins, remote state backend, provider features |
| `variables.tf` | Every input, with validation on the ones that break confusingly |
| `main.tf` | Resource group, virtual network, subnet, container registry, Log Analytics workspace, Key Vault |
| `aks.tf` | Cluster, autoscaling node pool, and the two role assignments it needs |
| `outputs.tf` | Names and IDs the later phases consume |

## First run

State lives in an Azure Storage account, which has to exist before Terraform has anywhere to
keep state. Create it once per subscription:

```bash
az login; make bootstrap
```

That writes `infra/backend.hcl` (not committed). Then:

```bash
make init; make validate; make plan
```

Once the plan looks right:

```bash
make up
```

`make up` prints the `az aks get-credentials` command for the new cluster.

## Every session after that

```bash
make up      # start of session
make down    # end of session, without exception
```

Rebuilding from scratch each time is the point. If `make up` stops working, that is a real
defect in the infrastructure code, and better found now than during Phase 2.

## Status

**Not yet validated.** This configuration was written before `terraform` was installed locally,
so nothing has run `terraform validate` against it. Expect the first `make validate` to surface
argument-name mismatches — the azurerm provider renamed a number of arguments in v4, and this
code targets v4.

Run `make fmt` and `make validate` before the first `make plan`, and fix what they report.

## Cost

The only resources that bill meaningfully are the node pool and the load balancer. `make cost`
prints rough daily figures. Nothing bills while the environment is destroyed.
