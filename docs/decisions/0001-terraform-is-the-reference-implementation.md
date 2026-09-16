# 0001 — Terraform is the reference implementation; Bicep, if ever, is script + apply

**Date:** 2026-09-16
**Status:** accepted

## Decision

APE is built in Terraform. A Bicep port is not planned. If a customer requires
Bicep, the shape is a pipeline script that reads and decides, handing a decision
to a Bicep module that applies it — not a port of the three modules.

## Why

APE is read → decide → apply. Bicep can do the third and not the first.

### Bicep cannot read the state this needs

`existing` requires a known resource ID and **fails the deployment with NotFound**
when the resource is absent. There is no `try`. That alone rules out the region
access probe, which exists precisely to turn a failed read into a reported
answer — see `ape-read`, where the whole point is that Germany North yields
`region_accessible = false` rather than a broken plan.

`deploymentScripts` is the documented workaround and is not a data source:

- It provisions a storage account and a container instance per run.
- It needs a managed identity with reader, and the role assignments that implies
  — which in most organisations is a security review, not a module input.
- **It is idempotent.** If no property of the `deploymentScripts` resource
  changes, the script does not run on redeploy. A read that will not re-read is
  worse than no read: quota state would be silently stale from the first
  deployment. The usual fix is salting it with a timestamp, which is an
  admission that it is not a data source.

Bicep extensibility does not change this. It is about deploying to targets
outside the ARM control plane — Kubernetes, GitHub, Microsoft Graph — with
third-party extensions still ahead. It is not a query mechanism.

### The decision logic would lose its tests

`terraform test` runs the whole decision surface against fixtures with no
subscription: 47 cases covering the growth restrictions, zone subtraction,
phantom families, non-zonal regions and the category rules. Bicep has no
equivalent. Porting the subtlest code in the project to a language where it
cannot be tested, alongside a Terraform copy that can, is how the two drift.

### Nobody does it this way

Surveying how this is actually done in Bicep, 2026-09-16:

| Approach | What it really is |
|---|---|
| Capacity chosen by branch or hardcoded in the template ([johnnyreilly][jr]) | Manual governance. Bicep is the deployment mechanism, not a quota-aware orchestrator. |
| PowerShell runbook in an Automation Account ([AzureAutoQuota][aaq]) | A script. Reads usage per family per region and requests increases. Closest prior art to `ape-apply`, and not IaC. |
| Bicep deploys a Logic App that queries quota ([azure-quotas-monitoring-logicapp][lam]) | Bicep deploys the machinery; the machinery does the reading. |

Every one of them puts the reading somewhere other than Bicep. That is not a
failure of imagination — it is what the tool supports.

## AVM does not require parity

AVM keeps language-specific specifications, with `BCP/` and `TF/` prefixes,
because "some specifications will be different between their respective
languages to ensure we follow the best practices and leverage features of each
language". A Terraform-only module is legitimate. Bicep is a customer-demand
question, not a compliance one.

## Cost of deferring

Low. `writes_required` is already a plain data contract that anything can
consume, so a Bicep apply module could be added later without changing the
Terraform side.

[jr]: https://johnnyreilly.com/azure-open-ai-capacity-quota-bicep
[aaq]: https://github.com/ClaudioMerola/AzureAutoQuota
[lam]: https://github.com/dawlysd/azure-quotas-monitoring-logicapp
