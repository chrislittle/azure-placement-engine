# APE: the manual

How to run the Azure Placement Engine, what its answers mean, and where it sits
in a subscription vending pipeline.

- [Where APE fits](#where-ape-fits)
- [Prerequisites](#prerequisites)
- [The intake](#the-intake)
- [Quickstart: Terraform](#quickstart-terraform)
- [Quickstart: Bicep](#quickstart-bicep)
- [Business rules](#business-rules)
- [Reading a decision](#reading-a-decision)
- [GitHub Actions](#github-actions)
- [Azure behaviour that will bite you](#azure-behaviour-that-will-bite-you)
- [Not covered yet](#not-covered-yet)

---

## Where APE fits

Microsoft's [subscription vending guidance][vending] describes a pipeline whose
deployment tasks are **Identity, Governance, Networking, Budgets and
Reporting**. Quota is not among them. CAF names the gap and does not fill it:

> They should also review the subscription quota limits before creating the
> subscription

> the quota request can fail, so you should run a script to handle any errors

APE is that script, as modules, and it runs as a **second stage** after vending.

```
  data collection tool                 (ITSM / portal / form)
          |
          v
  request pipeline  ------------->  subscription parameter file  (one per request)
          |                                    |
          v                                    |
  STAGE 1: avm-ptn-sub-vending                 |   same file
     creates the subscription                  |   read by both stages
          |                                    |
          |  subscription_id                   |
          v                                    v
  STAGE 2: APE            ape-read  ->  ape-placement  ->  ape-apply
     quota + placement    what exists    what to do        write it
          |
          v
  hand off to the application team
```

### Why two stages and not one module

A brand-new subscription does not exist at plan time. A single-stage module
would defer every read to apply, and the placement decision would never appear
in a plan. Run separately, stage 2 plans against a subscription that already
exists: the chosen family, the quota to be written, and why every other family
lost are all visible **before** anything is written.

It also matches the guidance's own advice to use a dedicated Terraform state
file per landing zone subscription, and it sidesteps a race — by the time stage
2 runs, `Microsoft.Compute` provider registration has settled.

**`subscription_id` is the entire handoff.** `avm-ptn-sub-vending` already
outputs it. The vending module needs no changes.

---

## Prerequisites

### Tooling

| Path | Needs |
|---|---|
| Terraform | Terraform >= 1.6 (for `terraform test`), `Azure/azapi` provider >= 2.0 |
| Bicep | PowerShell 7+, `Az.Accounts`, `powershell-yaml`, Bicep CLI |

### Permissions

On the **vended subscription**, the identity running stage 2 needs:

| Role | Why |
|---|---|
| **Reader** | `Microsoft.Compute/skus`, `locations/usages`, and the provider registration |
| **Quota Request Operator** | `Microsoft.Quota/quotas/write` — and `Microsoft.Support/*`, for raising a ticket when a request is refused |

`Quota Request Operator` is a built-in role and is exactly scoped to this job.
Contributor also works but grants far more than APE needs.

### Authentication

Both paths use whatever the environment is already signed in as — `az login`
locally, or OIDC federated credentials in CI. Nothing stores credentials.

---

## The intake

One YAML file per request, the "subscription parameter file" the guidance
describes. Both stages read it; APE only reads `compute:`.

See [`examples/vending-stage-2/intake.example.yaml`](../examples/vending-stage-2/intake.example.yaml)
for the full annotated version.

```yaml
compute:
  region: eastus
  vcpus: 64

  # Azure's own vmCategories vocabulary:
  #   GeneralPurpose | ComputeOptimized | MemoryOptimized | StorageOptimized
  #   GpuAccelerated | FpgaAccelerated  | HighPerformanceCompute
  category: MemoryOptimized

  # Optional attributes. Omit one and it is not filtered on.
  architecture: x64                 # x64 | Arm64
  burstable: Excluded               # Excluded | Required
  # confidential_computing: Required

  # Optional placement. Not a preference -- it decides which families are
  # eligible at all, because zone access is granted per SKU size and per zone.
  placement:
    type: zone_redundant            # regional | zonal | zone_redundant
    zone_count: 3
    # zones: ["1", "2"]             # for type: zonal

  # Optional, most specific wins.
  # family_allowlist: [standardEdsv6Family, standardEsv6Family]
  # family: standardEdsv6Family
```

**The application team states a workload class, not a VM family.** Nobody
filling in a subscription request knows what `standardEDSv5Family` is, and they
should not have to.

---

## Quickstart: Terraform

```bash
cd examples/vending-stage-2
terraform init

terraform apply \
  -var subscription_id="$(terraform -chdir=../stage-1 output -raw subscription_id)"
```

Writes are **off by default** so the decision can be reviewed. To let it write:

```bash
terraform apply -var subscription_id="$SUB" -var apply_writes=true
```

### Using the modules directly

```hcl
module "read" {
  source          = "../../modules/ape-read"
  subscription_id = var.subscription_id
  region          = local.compute.region
}

module "placement" {
  source     = "../../modules/ape-placement"
  request    = local.request
  pool       = module.read.pool
  sku_access = module.read.sku_access
  rules      = var.placement_rules
}

module "apply" {
  source          = "../../modules/ape-apply"
  subscription_id = var.subscription_id
  region          = local.compute.region
  writes_required = module.placement.writes_required
  enabled         = var.apply_writes
}
```

> **Consuming `ape-read` from outside this repo:** it reads the curated lists
> from `knowledge/` by a path relative to itself. A non-local module source
> makes Terraform copy the module into `.terraform/modules`, which breaks that
> path. Set `knowledge_dir` explicitly when that happens.

---

## Quickstart: Bicep

```bash
pwsh -File examples/vending-stage-2-bicep/Invoke-ApeVending.ps1 \
  -SubscriptionId $SUB
```

Evaluates the decision and writes `ape-apply.bicepparam`. Nothing is deployed.
Add `-Deploy` to apply it.

Bicep cannot read quota state — see
[decision 0001](decisions/0001-terraform-is-the-reference-implementation.md) —
so on this path PowerShell reads and decides and Bicep only writes:

```
PowerShell:  read quota + SKUs  ->  decide  ->  ape-apply.bicepparam
Bicep:       ape-apply.bicep    ->  write the quota
```

The script forms no opinion of its own. It serialises `writes_required`
unchanged, so Bicep receives exactly what the Terraform module would have
applied.

### Using the PowerShell modules directly

```powershell
Import-Module ./powershell/ApeRead.psm1
Import-Module ./powershell/ApePlacement.psm1

$state = Get-ApeState -SubscriptionId $sub -Region eastus
$decision = Get-ApePlacement -Request $request -Pool $state.pool `
    -SkuAccess $state.sku_access -Rules $rules
```

---

## Business rules

Rules belong to the **platform team**, not the requester, so they live in the
module call rather than the intake. Evaluated in order; the first whose
`environments` matches wins. A rule with no `environments` matches everything,
so put the catch-all last.

```hcl
rules = [
  {
    name            = "devtest stays off GPU and stays small"
    environments    = ["devtest"]
    family_denylist = ["standardNCSv3Family", "standardNVSv4Family"]
    max_vcpus       = 32
  },
  {
    name             = "prod uses approved families, cheapest first"
    environments     = ["prod"]
    family_allowlist = ["standardDsv6Family", "standardDdsv6Family"]
    prefer           = "listed_order"
  },
]
```

| Field | Effect |
|---|---|
| `environments` | Which `subscription.environment` values this rule applies to |
| `family_allowlist` | Only these families are candidates |
| `family_denylist` | These families are removed |
| `max_vcpus` | Requests above this are refused with `blocked_by_rule` |
| `prefer` | `most_headroom` (default), `least_headroom`, or `listed_order` |

`listed_order` means the order the rule's own allowlist names them — how a
platform team says "use up the cheap family first".

---

## Reading a decision

`status` is the load-bearing field. Every value tells you what to do next.

| `status` | Meaning | What to do |
|---|---|---|
| `satisfied` | Existing quota covers it. | Nothing. `writes_required` is empty. |
| `needs_allocation` | A quota group can cover the shortfall. | Apply. Allocation is self-service and will succeed. |
| `needs_increase` | A quota limit increase is required. | Apply, but **this is not a promise** — increases are evaluated, not granted. |
| `not_ready` | `Microsoft.Compute` is not registered yet. | **Wait and retry.** Transient, and normal right after vending. |
| `blocked_by_region` | The subscription cannot reach the region at all. | Region access request. No quota action helps. |
| `blocked_by_lifecycle` | Every candidate is under the July 2026 capacity growth restrictions. | Use a successor family — the reason names them. |
| `blocked_by_access` | No candidate can deploy here. | Read `access.remediation`; it names the right ticket, or says there isn't one. |
| `blocked_by_rule` | A business rule refused it. | Change the request or the rule. |
| `infeasible` | No candidate family can reach the requested size. | Different region, family, or size. |

Other fields worth reading:

- **`considered`** — every candidate with its numbers and why it lost. *"Why not
  that family"* is most of what anyone actually asks.
- **`access.remediation`** — names the specific ticket: region/SKU access, zonal
  enablement, or none at all when the offer excludes the SKU or the region has
  no zones.
- **`lifecycle.frozen`** — families usable only within quota already held.
- **`regional.increase_required`** — the region-wide vCPU cap binds, separately
  from the family limit.

### When a write is refused

A refused quota write **fails the apply on purpose**. Terraform cannot catch a
resource error, and it is the right outcome anyway: a vended subscription that
cannot run its workload is a failure, not a caveat.

Three refusal codes, **none retryable**:

| Code | Meaning |
|---|---|
| `ContactSupport` | Self-service is exhausted. A ticket is the only route. |
| `QuotaNotAvailableForResource` | Capacity is not there for this subscription. A smaller ask fares no better. |
| `DeprecatedQuotaType` | The family is growth-restricted. `ape-placement` predicts this one, so it should never reach the apply. |

---

## GitHub Actions

Three workflows ship in [`.github/workflows`](../.github/workflows):

| Workflow | Trigger | What it does |
|---|---|---|
| `conformance.yml` | push, PR | Runs both implementations against the shared scenarios, plus `terraform test`. **No Azure needed.** |
| `vend-stage-2-terraform.yml` | `workflow_dispatch` | Stage 2, Terraform path. Plans by default; writes only when asked. |
| `vend-stage-2-bicep.yml` | `workflow_dispatch` | Stage 2, Bicep path. |

### Wiring stage 2 to stage 1

Stage 2 needs one value from stage 1. In a single pipeline:

```yaml
  stage-1-vending:
    runs-on: ubuntu-latest
    outputs:
      subscription_id: ${{ steps.vend.outputs.subscription_id }}
    steps:
      - id: vend
        run: |
          terraform -chdir=stage-1 apply -auto-approve
          echo "subscription_id=$(terraform -chdir=stage-1 output -raw subscription_id)" >> "$GITHUB_OUTPUT"

  stage-2-quota:
    needs: stage-1-vending
    uses: ./.github/workflows/vend-stage-2-terraform.yml
    with:
      subscription_id: ${{ needs.stage-1-vending.outputs.subscription_id }}
      intake_file: requests/contoso-payments-api.yaml
      apply_writes: true
```

### Authentication

The workflows use OIDC — no stored secrets:

```yaml
permissions:
  id-token: write
  contents: read
```

with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` as
repository variables. The federated credential needs Reader and Quota Request
Operator on the vended subscription.

### Reviewing before writing

The useful shape is **plan on the PR, apply on merge**. Stage 2 plans cleanly
against an existing subscription, so the decision — chosen family, quota to be
written, why every other family lost — shows up in the PR before anything
happens.

---

## Azure behaviour that will bite you

All of this is recorded, dated and sourced in [`knowledge/`](../knowledge). The
short version:

**Quota is not evidence a family exists.** A family can report a healthy limit
in a region where Azure offers no sizes of it. On a live subscription, 14 of 97
families holding quota in East US had zero SKUs there.

**`locationInfo[].zones` overstates.** `restrictions[]` removes zones, and the
restricted list is not constrained to be a subset of the published one.
`Standard_D1` in East US publishes zones 2 and 3 while restricting 1, 2 and 3 —
netting to nothing deployable zonally.

**A Zone restriction does not block regional placement.** Confirmed by
deployment, not documented by Microsoft.

**Some regions have no zones at all.** West Central US reports 916 VM SKUs and
not one zone. There is no ticket that adds zones to a region.

**`Microsoft.Compute/skus` cannot see region access.** For Germany North — which
one test subscription cannot deploy to — it returned 866 VM SKUs of which 796
carried no restriction whatsoever. Only the quota read reveals the gap.

**New subscriptions cannot deploy growth-restricted series at all.** Not "cannot
grow" — cannot deploy. That is 30 series, and on one live subscription, 25 of
the 97 families holding quota in East US.

**A `202` from a quota PUT is not an approval.** It means Azure agreed to
evaluate. Observed: `InProgress` for ~35 seconds, then `Failed`.

**`isQuotaApplicable` is not a pre-check.** It returned `true` for a family
whose write was then structurally refused.

---

## Not covered yet

**Quota groups.** `Microsoft.Quota/groupQuotas` would let a platform pool quota
across subscriptions and reallocate it self-service — including harvesting
unused quota from existing subscriptions. The design is researched and the
contract is in place (`pool.families[*].available` is the hook), but it needs an
EA, MCA-Enterprise or Internal billing account to exercise. See
[`knowledge/quota-groups.yaml`](../knowledge/quota-groups.yaml).

**The ODCR capacity buffer.** Deferred deliberately. A capacity reservation
binds to an exact VM size, which suits a customer who has already fixed on one
and not the flexible-intake case that is most of the value. It also needs quota
in the *consuming* subscription, which growth restrictions can make
unobtainable. See [`knowledge/capacity-signals.yaml`](../knowledge/capacity-signals.yaml).

[vending]: https://learn.microsoft.com/en-us/azure/architecture/landing-zones/subscription-vending
