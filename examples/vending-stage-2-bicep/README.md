# Stage 2, the Bicep way

The same stage-2 job as [`../vending-stage-2`](../vending-stage-2), for shops
that run Bicep rather than Terraform.

```bash
pwsh -File Invoke-AqvVending.ps1 -SubscriptionId <from stage 1>
pwsh -File Invoke-AqvVending.ps1 -SubscriptionId <from stage 1> -Deploy
```

Writes are off by default, so the decision can be reviewed before anything is
written. It reads the **same request file** as the Terraform path.

## Why this is a script and a template, not a module

Bicep cannot read quota state — see
[decision 0001](../../docs/GUIDE.md#why-bicep-works-differently).
`existing` fails the whole deployment with `NotFound` when a resource is absent.
`deploymentScripts` is idempotent, so a quota read would keep its first value.

So the shape is:

```
PowerShell:  read quota + SKUs  ->  decide  ->  aqv-apply.bicepparam
Bicep:       aqv-apply.bicep    ->  write the quota
```

On the Terraform path all three steps are Terraform. Here only the last one can
be Bicep.

The script makes no decision of its own. It serialises `writes_required`
unchanged, so the Bicep template receives what the Terraform module would
apply.

## Drift

The decision logic exists twice. [`conformance/`](../../conformance) holds one
set of scenarios. Both implementations must pass all of them. Run it in CI.
