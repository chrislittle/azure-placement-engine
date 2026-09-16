# `aqv-apply`

Writes the quota limits a placement decision asked for. Takes
[`aqv-decide`](../aqv-decide)'s `writes_required` without change.

## Usage

```hcl
module "apply" {
  source          = "../../modules/aqv-apply"
  subscription_id = var.subscription_id
  region          = "eastus"
  writes_required = module.placement.writes_required
}
```

An empty `writes_required` means the decision needs no write. The module then
creates nothing.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `subscription_id` | string | **required** | Subscription whose quota is written. |
| `region` | string | **required** | Azure region the quota applies to. |
| `writes_required` | list(object) | `[]` | From `aqv-decide`. Each item has `scope`, `name` and `limit`. |
| `enabled` | bool | `true` | Set `false` to evaluate a decision without writing. |

Each `scope` is `regional` or `family`. Each `limit` is the new absolute value,
not an increase.

## Outputs

| Name | Type | Description |
|---|---|---|
| `applied` | list | Each write, with the limit Azure returned. |
| `pending` | list | Writes Azure accepted but did not grant. |

A limit in `pending` that is lower than the requested value means the
self-service path is exhausted. Raise a support request. The write was not lost.

## Order

The module writes the regional vCPU cap before the family limit. A family limit
above the regional cap cannot be used.

## A refused write fails the apply

Terraform cannot catch a resource error, so a refusal cannot become a warning.
This is also the correct result. A vended subscription that cannot run its
workload is a failed vending.

Azure refuses a quota write with one of three codes. Do not retry any of them.

| Code | Meaning | Action |
|---|---|---|
| `ContactSupport` | Self-service is exhausted. | Raise a support request. |
| `QuotaNotAvailableForResource` | Capacity is not available for this subscription. | Choose another region or size. A smaller request does not help. |
| `DeprecatedQuotaType` | The family is growth-restricted. | Choose a successor family. `aqv-decide` predicts this, so it should not reach the apply. |

## Timing

A quota PUT returns `202` and completes asynchronously. The azapi provider polls
`operationsStatus` until it finishes. No extra polling is needed.

The wait is not predictable. The same operation has taken 35 seconds through the
REST API and 95 seconds through Terraform. Set generous timeouts.

## Why `azapi_update_resource`

A quota limit is a property of a resource Azure already owns. It is not a
resource with its own lifecycle. `Microsoft.Quota` has no DELETE, so a managed
`azapi_resource` fails on `terraform destroy`. `azapi_update_resource` writes
the property and stops managing it on destroy.

This works as desired state because `limit` is absolute.

## Bicep equivalent

[`bicep/aqv-apply.bicep`](../../bicep/aqv-apply.bicep) performs the same writes
for the Bicep path.
