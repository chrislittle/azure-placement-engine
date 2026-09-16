# Conformance

APE ships two implementations of the same decision:

| Path | read | decide | apply |
|---|---|---|---|
| **Terraform** | `modules/ape-read` | `modules/ape-placement` | `modules/ape-apply` |
| **Bicep** | `powershell/ApeRead.psm1` | `powershell/ApePlacement.psm1` | `bicep/ape-apply.bicep` |

Bicep cannot read quota state (see [the manual](../docs/GUIDE.md#why-bicep-works-differently)),
so on that path PowerShell reads and decides and Bicep only writes. That means
**the decision logic exists twice**, which is a real cost.

This directory is how that cost is contained. One set of scenarios; both
implementations must produce the same answer.

```bash
# Terraform — no subscription needed, one apply covers every scenario
terraform -chdir=conformance/terraform init
terraform -chdir=conformance/terraform apply -auto-approve
```

```bash
pwsh -File conformance/powershell/Invoke-Conformance.ps1 -Detailed
```

Both exit non-zero on a mismatch, so either can gate a pipeline.

## A scenario

`scenarios/*.json` is language-neutral: the four inputs a decision takes, plus
what it should produce.

```json
{
  "description": "why this case exists",
  "request":    { "region": "eastus", "vcpus": 8, "category": "GeneralPurpose" },
  "pool":       { "...": "..." },
  "sku_access": {},
  "rules":      [],
  "expect":     { "status": "satisfied", "family": "standardDSv5Family", "writes_required": 0 }
}
```

Only the keys present in `expect` are asserted, so a scenario can pin one
behaviour without restating everything else.

## It has already earned its keep

Writing the PowerShell implementation against these scenarios caught three
divergences that would otherwise have shipped:

- **Tie-breaking.** Terraform ranked with `reverse(sort())`, which reverses the
  family name order as well as the headroom order, so on a headroom tie it chose
  the *last* family alphabetically. PowerShell's `Sort-Object` is
  case-insensitive and chose a different one. On live East US data the two
  picked different families. Both now build the same padded sort key and compare
  it ordinally, and `tie-break-is-ordinal.json` pins it.

- **`zone_redundant` placement.** Broken in PowerShell and covered by no
  scenario, so only the live driver hit it. Two scenarios now cover it.

- **A real bug in the Terraform module**, found while writing the fixtures:
  `region_zonal` was computed from *effective* zones, so a perfectly zonal
  region looked non-zonal as soon as every family examined happened to be fully
  zone-restricted — and the customer was then told no ticket could help, which
  is the opposite of the truth. It now reads published zones.

## Adding one

Add a JSON file. Both runners pick it up automatically; neither needs editing.

When the two implementations disagree, that is the point — fix whichever is
wrong and keep the scenario.
