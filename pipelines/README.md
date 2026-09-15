# pipelines

Azure DevOps multi-stage pipeline definitions.

| File | Contents |
|------|----------|
| `azure-pipelines.yml` | Entry point: verify, then dev, test and prod |
| `templates/deploy-stage.yml` | The deployment stage, parameterised by environment |

All three environments use the same template. The only differences are the namespace and the
kustomize overlay, because an environment that deploys differently from production proves
nothing about production.

See [docs/delivery.md](../docs/delivery.md) for the promotion flow, the rollback path, who
approves production, and what has to be configured in Azure DevOps before any of this runs.

**Status:** written and YAML-validated, never executed. It needs the Azure DevOps organisation,
two service connections, three Environments and a variable group first.
