# Stage 2, the Bicep way

The same stage-2 job as [`../vending-stage-2`](../vending-stage-2), for shops
that run Bicep rather than Terraform.

```bash
pwsh -File Invoke-ApeVending.ps1 -SubscriptionId <from stage 1>
pwsh -File Invoke-ApeVending.ps1 -SubscriptionId <from stage 1> -Deploy
```

Writes are off by default, so the decision can be reviewed before anything is
written. It reads the **same intake file** as the Terraform path.

## Why this is a script and a template, not a module

Bicep cannot read quota state — see
[decision 0001](../../docs/decisions/0001-terraform-is-the-reference-implementation.md).
`existing` fails the whole deployment with `NotFound` when a resource is absent,
and `deploymentScripts` is idempotent, so a quota read would be silently stale
from the first deployment onward.

So the shape is:

```
PowerShell:  read quota + SKUs  ->  decide  ->  ape-apply.bicepparam
Bicep:       ape-apply.bicep    ->  write the quota
```

On the Terraform path all three steps are Terraform. Here only the last one can
be Bicep.

The script forms no opinion of its own about what should happen — it serialises
`writes_required` unchanged, so the Bicep template receives exactly what the
Terraform module would have applied.

## Drift

The decision logic exists twice. [`conformance/`](../../conformance) holds one
set of scenarios both implementations must pass, and it has already caught three
divergences that would otherwise have shipped. Run it in CI.
