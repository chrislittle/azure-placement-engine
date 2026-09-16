# `aqv-read`

Reads the quota, the SKU availability and the region access for one subscription
in one region. Produces the two inputs that
[`aqv-decide`](../aqv-decide) needs.

This module reads. It creates and changes nothing.

## Usage

```hcl
module "read" {
  source          = "../../modules/aqv-read"
  subscription_id = var.subscription_id
  region          = "eastus"
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `subscription_id` | string | **required** | Subscription to read. |
| `region` | string | **required** | Azure region, for example `eastus`. |
| `knowledge_dir` | string | `null` | Path to the `knowledge/` directory. Defaults to the copy beside this module. |

Set `knowledge_dir` when Terraform copies this module. A non-local module source
places it under `.terraform/modules`, which breaks the relative path.

## Outputs

| Name | Type | Description |
|---|---|---|
| `quota` | object | Quota state. Pass to `aqv-decide`'s `quota`. |
| `sku_access` | map | Deployable SKU sizes and their zones. Pass to `aqv-decide`'s `sku_access`. |
| `region_accessible` | bool | `false` when the subscription cannot use the region. |
| `provider_registered` | bool | `false` when `Microsoft.Compute` is not registered yet. |

## Region access is read first

Compute usages returns HTTP 400 `NoRegisteredProviderFound` for a region the
subscription cannot use. A Terraform data source cannot catch that error. It
fails the whole plan.

This module therefore reads the `Microsoft.Compute` provider registration first.
The registration lists the regions the subscription can use. Both larger reads
then run only when the region is in that list. An unusable region produces no
families and `region_accessible = false`.

`Microsoft.Compute/skus` cannot detect a missing region grant. It returns a full
catalogue for regions the subscription cannot use.

## Curated data

The module reads `knowledge/vm-series-lifecycle.yaml` with `yamldecode`. The
list of growth-restricted families has one source.

## Cost

About 7.5 seconds for one region. The module reads roughly 1500 SKUs and 230
usage entries, then groups them by family.

## PowerShell equivalent

[`powershell/AqvRead.psm1`](../../powershell/AqvRead.psm1) performs the same
reads for the Bicep path. See
[the manual](../../docs/GUIDE.md#why-bicep-works-differently).
