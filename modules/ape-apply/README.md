# `ape-apply`

Writes the quota that a placement decision asked for. Takes
[`ape-placement`](../ape-placement)'s `writes_required` unchanged.

```hcl
module "apply" {
  source          = "../../modules/ape-apply"
  subscription_id = var.subscription_id
  region          = var.region
  writes_required = module.placement.writes_required
}
```

Empty `writes_required` means the decision needs nothing written, and this
module does nothing. Set `enabled = false` to evaluate a vending without
writing.

## A refused write fails the apply, on purpose

Terraform has **no way to catch a resource error**, so a quota refusal cannot be
turned into a warning. That is also the right outcome: a vended subscription
that cannot run its workload is a failure, not a caveat.

Three distinct refusal codes, **none of them retryable** — re-running the apply
will not help:

| Code | Meaning |
|---|---|
| `ContactSupport` | Self-service is exhausted. A support ticket is the only remaining route. |
| `QuotaNotAvailableForResource` | Capacity is not there for this subscription. Observed on a current v6 family, and a smaller ask fared no better — the refusal is about the subscription, not the size of the request. |
| `DeprecatedQuotaType` | The family is under the capacity growth restrictions. Returns 400 immediately. `ape-placement`'s lifecycle gate predicts this one, so it should never reach here. |

`ape-placement` narrows the odds by refusing to emit writes it can tell will be
rejected, but `ContactSupport` and `QuotaNotAvailableForResource` depend on
regional capacity and cannot be predicted from any API.

## Timing

A quota PUT returns `202` and settles asynchronously. azapi polls
`operationsStatus` to completion by itself — no custom polling needed — but the
latency is not reliable: the same class of operation resolved in about 35
seconds via REST and took 95 seconds through Terraform. Budget generously.

## Why `azapi_update_resource`

A quota limit is a property of something Azure already owns, not a resource with
its own lifecycle. `Microsoft.Quota` has no DELETE, so a managed
`azapi_resource` would fail on `terraform destroy`. `azapi_update_resource`
writes the property and simply stops managing it on destroy.

This works as desired state because `limit` is **absolute, never a delta**.

## Ordering

The regional vCPU cap is written before the family limit, via `depends_on`. A
family limit above the regional cap is unusable, so raising the family without
raising the cap buys nothing.
