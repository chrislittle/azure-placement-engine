# Conformance

APE ships two implementations of the same decision:

| Path | read | decide | apply |
|---|---|---|---|
| **Terraform** | `modules/ape-read` | `modules/ape-placement` | `modules/ape-apply` |
| **Bicep** | `powershell/ApeRead.psm1` | `powershell/ApePlacement.psm1` | `bicep/ape-apply.bicep` |

Bicep cannot read quota state. See
[the manual](../docs/GUIDE.md#why-bicep-works-differently). On that path
PowerShell reads and decides, and Bicep writes.

The decision logic therefore exists twice. This directory holds one set of
scenarios. Both implementations must produce the same answer for every one.

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

## What it has caught

Writing the PowerShell implementation against these scenarios found three
defects before release.

**Tie-breaking.** Terraform ranked with `reverse(sort())`. That reverses the
family name order as well as the headroom order, so a headroom tie selected the
last family alphabetically. PowerShell used `Sort-Object`, which ignores case.
The two implementations chose different families. Both now build the same padded
sort key and compare it as ordinal text.

**`zone_redundant` placement.** The PowerShell implementation was wrong and no
scenario covered it. Two scenarios now do.

**A defect in the Terraform module.** `region_zonal` was calculated from
effective zones instead of published zones. A region with zones appeared to have
none whenever every family examined was fully restricted. The module then told
the user that no support request would help, which was incorrect. It now reads
published zones.

## Adding one

Add a JSON file. Both runners pick it up automatically; neither needs editing.

When the two implementations disagree, that is the point — fix whichever is
wrong and keep the scenario.
