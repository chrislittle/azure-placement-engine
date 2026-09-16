# `ape-placement`

Chooses a VM family for a subscription and calculates the quota limit to set.
Returns the decision, the reason for it, and the reason each other family was
rejected.

This module contains no resources. It reads nothing from Azure. The caller
supplies the state, usually from [`ape-read`](../ape-read).

That separation makes the whole decision testable without a subscription:

```bash
terraform test
```

## Usage

```hcl
module "placement" {
  source = "../../modules/ape-placement"

  request = {
    region   = "eastus"
    vcpus    = 64
    category = "MemoryOptimized"
  }

  pool       = module.read.pool
  sku_access = module.read.sku_access
  rules      = var.placement_rules
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `request` | object | **required** | What the workload needs. See below. |
| `pool` | object | **required** | Quota state for the region. From `ape-read`. |
| `sku_access` | map | `{}` | Deployable sizes and zones. Empty skips the access check. |
| `rules` | list(object) | `[]` | Platform business rules. |

### `request`

| Field | Type | Default | Values |
|---|---|---|---|
| `region` | string | **required** | Azure region name. |
| `vcpus` | number | **required** | Greater than 0. |
| `category` | string | any | `GeneralPurpose`, `ComputeOptimized`, `MemoryOptimized`, `StorageOptimized`, `GpuAccelerated`, `FpgaAccelerated`, `HighPerformanceCompute` |
| `architecture` | string | any | `x64`, `Arm64` |
| `burstable` | string | any | `Excluded`, `Required` |
| `confidential_computing` | string | any | `Excluded`, `Required` |
| `family_allowlist` | list(string) | all | Azure family names. |
| `family` | string | none | One Azure family name. |
| `environment` | string | `prod` | Selects which rule applies. |
| `new_subscription` | bool | `true` | `false` for a subscription that already holds quota. |
| `placement.type` | string | `regional` | `regional`, `zonal`, `zone_redundant` |
| `placement.zones` | list(string) | none | Required when `type` is `zonal`. |
| `placement.zone_count` | number | `3` | Used when `type` is `zone_redundant`. |

Three fields narrow the candidates. The most specific wins: `family`, then
`family_allowlist`, then `category` and the attribute fields.

### `pool`

| Field | Type | Default | Description |
|---|---|---|---|
| `regional_cores_limit` | number | **required** | Region-wide vCPU cap. |
| `regional_cores_used` | number | **required** | vCPUs in use. |
| `region_accessible` | bool | `true` | `false` blocks everything below it. |
| `provider_registered` | bool | `true` | `false` gives `not_ready`. |
| `families` | map(object) | **required** | One entry for each family. |

Each family entry:

| Field | Type | Default | Description |
|---|---|---|---|
| `limit` | number | **required** | Current quota limit. |
| `used` | number | **required** | vCPUs in use. |
| `available` | number | `null` | Spare quota in a quota group. `null` means no pool. |
| `category` | string | `null` | Azure vmCategory. |
| `lifecycle` | string | `current` | `current`, `previous_gen`, `capacity_limited`, `growth_restricted`, `retirement_announced` |
| `successors` | list(string) | `[]` | Replacement families, named in the reason. |
| `burstable` | bool | `false` | |
| `confidential_computing` | bool | `false` | |
| `architectures` | list(string) | `[]` | `x64`, `Arm64`, or both. |

### `rules`

Evaluated in order. The first rule whose `environments` matches is used. A rule
with no `environments` matches every request, so place it last.

| Field | Type | Description |
|---|---|---|
| `name` | string | Reported in the decision. |
| `environments` | list(string) | Which `request.environment` values this rule applies to. |
| `family_allowlist` | list(string) | Limits candidates to this list. |
| `family_denylist` | list(string) | Removes these candidates. |
| `max_vcpus` | number | Larger requests give `blocked_by_rule`. |
| `prefer` | string | `most_headroom` (default), `least_headroom`, `listed_order`. |

`listed_order` uses the order of the rule's own `family_allowlist`.

## Outputs

| Name | Type | Description |
|---|---|---|
| `decision` | object | The decision and the reasoning. |
| `writes_required` | list | Pass to [`ape-apply`](../ape-apply). Empty when no write is needed. |

### `decision`

| Field | Description |
|---|---|
| `status` | See the table below. |
| `reason` | One sentence explaining the status. |
| `family` | The chosen family, or `null`. |
| `category` | The requested category, or `null`. |
| `target_limit` | The absolute limit to set, or `null`. |
| `regional` | The region-wide cap, its headroom, and whether it must be raised. |
| `lifecycle` | Families refused by the growth restrictions, and their successors. |
| `access` | Region and zone access, and the remediation for a refusal. |
| `considered` | Each candidate, its numbers, and why it lost. |
| `rule_applied` | The rule used, or `(none)`. |
| `unknown_families` | Named families the pool does not contain. |

### `status`

| Value | Meaning | Action |
|---|---|---|
| `satisfied` | Existing quota covers the request. | None. |
| `needs_allocation` | A quota group covers the shortfall. | Apply. Allocation is self-service. |
| `needs_increase` | A quota limit increase is needed. | Apply. Azure evaluates the request. It is not a promise. |
| `not_ready` | `Microsoft.Compute` is not registered. | Wait, then retry. |
| `blocked_by_region` | The subscription cannot use the region. | Raise a region access request. |
| `blocked_by_lifecycle` | Every candidate is growth-restricted. | Use a successor family. The reason names them. |
| `blocked_by_access` | No candidate can deploy here. | Read `access.remediation`. |
| `blocked_by_rule` | A business rule refused the request. | Change the request or the rule. |
| `infeasible` | No candidate can reach the requested size. | Change region, family or size. |

## Behaviour

### The regional cap

`regional_cores_limit` applies to every family. It is not the sum of the family
limits. It is usually much smaller. A subscription can report a cap of 10 vCPUs
and 97 families that each report 10 to 12.

Ranking on family headroom alone therefore finds vCPUs that cannot be deployed.
Every decision respects the cap. When the cap binds, `writes_required` raises it
first, because a family limit above the cap cannot be used.

### Quota is not proof a family exists

A family can hold quota in a region where Azure offers no sizes of it. Supply
`sku_access` and the module treats an absent family as not offered. It reports
those in `access.not_offered`, separately from `access.denied`, because no
support request changes them.

`sku_access` must be complete for the region, or empty.

### Zones

`sku_access` carries the published zones and the restricted zones for each size.
The module subtracts them. The restricted list is not a subset of the published
list, so a size can publish two zones, restrict three, and leave none.

A `Zone` restriction blocks zonal placement only. Regional placement of the same
family still works.

Some regions have no zones. The module reports `access.region_zonal = false` and
`access.requestable = false`, because no support request adds zones to a region.

### Growth-restricted families

A new subscription cannot deploy the growth-restricted series at all. An
existing subscription can deploy them within quota it already holds, but cannot
obtain more. Set `request.new_subscription` correctly.

### Unproven capacity

`available = null` means no quota group sits behind the subscription. The module
treats that as unproven, not as unlimited. This is what separates
`needs_allocation` from `needs_increase`.

### Rejected candidates are recorded

`decision.considered` lists every candidate with its numbers and the reason it
lost. "Why not that family" is the common question.

## PowerShell equivalent

[`powershell/ApePlacement.psm1`](../../powershell/ApePlacement.psm1) implements
the same decision for the Bicep path. Both pass the scenarios in
[`conformance/`](../../conformance).
