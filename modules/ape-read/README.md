# `ape-read`

Reads live Azure state and projects it into the `pool` and `sku_access` inputs
[`ape-placement`](../ape-placement) expects. All Terraform — no pipeline step,
no generated tfvars.

```hcl
module "read" {
  source          = "../../modules/ape-read"
  subscription_id = var.subscription_id
  region          = "eastus"
}

module "placement" {
  source     = "../../modules/ape-placement"
  request    = var.request
  pool       = module.read.pool
  sku_access = module.read.sku_access
}
```

This module talks to Azure and holds no logic worth testing. `ape-placement`
holds all the logic and talks to nothing. That split is deliberate: the
decisions stay testable against fixtures with no subscription.

## Region access has to be probed first

Asking Compute usages about a region the subscription lacks returns HTTP 400
`NoRegisteredProviderFound` — and a Terraform data source **cannot catch that**.
It fails the whole plan, so the module could never report the condition.

So the first read is the `Microsoft.Compute` provider registration, whose
`resourceTypes[].locations` is the list of regions this subscription may use.
Both expensive reads are then gated on `count`, and an unreachable region
yields an empty pool with `region_accessible = false` instead of a broken plan.

`Microsoft.Compute/skus` cannot substitute: for Germany North it returns 866 VM
SKUs of which 796 carry no restriction at all, for a subscription that cannot
deploy there.

## Curated knowledge is read, not copied

`yamldecode(file(...))` reads `knowledge/` directly, so the growth-restricted
family list and the class rules have exactly one home. Override `knowledge_dir`
only when consuming this module from somewhere the relative path can't reach.

## Cost

About **7.5 seconds** for a region: roughly 1500 SKUs and 230 usage entries
fetched and projected, including the family grouping, which is O(families x
SKUs) because HCL has no group-by. Acceptable for a vending operation.

Verified identical to the Python reader across East US, West Europe, Central US
and West Central US — same family counts, same growth-restricted counts, same
chosen family.

## `scripts/read_pool.py`

Superseded for the live path, kept for generating test fixtures offline and as
the reference the Terraform projection was checked against.
