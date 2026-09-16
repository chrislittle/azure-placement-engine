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
- [Azure behaviour to know](#azure-behaviour-to-know)
- [Not covered yet](#not-covered-yet)

---

## Where APE fits

Microsoft's [subscription vending guidance][vending] lists five deployment
tasks: identity, governance, networking, budgets and reporting. Quota is not one
of them. The Cloud Adoption Framework states the problem but does not solve it:

> They should also review the subscription quota limits before creating the
> subscription

> the quota request can fail, so you should run a script to handle any errors

APE is that script. It runs as a second stage, after the subscription exists.

```mermaid
flowchart LR
    A[Data collection tool] --> B[Request pipeline]
    B --> C[Subscription parameter file]
    C --> D[Stage 1: sub-vending]
    D -- subscription_id --> E[Stage 2: APE]
    E --> F[Application team]
```

Stage 1 creates and configures the subscription. Stage 2 gives it quota.

| Stage | Module | Task |
|---|---|---|
| 1 | `avm-ptn-sub-vending` | Create the subscription. Apply identity, governance, networking and budgets. |
| 2 | `ape-read` | Read the quota, the SKUs and the region access. |
| 2 | `ape-placement` | Choose a VM family. Calculate the quota to set. |
| 2 | `ape-apply` | Write the quota. |

Both stages read the same parameter file. Stage 1 gives stage 2 one value: the
subscription ID.

### Why two stages and not one module

A new subscription does not exist when Terraform makes a plan. One module would
have to defer every read until apply. The placement decision would then never
appear in a plan.

Stage 2 runs against a subscription that already exists. The plan shows the
chosen family, the quota to write, and the reason each other family was
rejected. You can review all of it before anything is written.

Two stages give three more benefits:

- A separate state file for each landing zone subscription, as the guidance
  recommends.
- No race with provider registration. Registration completes during stage 1.
- No change to the vending module. It already outputs the subscription ID.

---

## Prerequisites

### Tooling

| Path | Needs |
|---|---|
| Terraform | Terraform >= 1.9 (CI gates on 1.9.8), `Azure/azapi` provider >= 2.0 |
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

One YAML file for each request. Both stages read it. APE reads only the
`compute:` block.

### Minimum

```yaml
compute:
  region: eastus
  vcpus: 64
```

### Every option

All fields are optional except `region` and `vcpus`. Omit a field and APE does
not filter on it.

| Field | Type | Default | Values |
|---|---|---|---|
| `region` | string | **required** | Any Azure region name, for example `eastus`. |
| `vcpus` | number | **required** | Greater than 0. |
| `category` | string | any | `GeneralPurpose`, `ComputeOptimized`, `MemoryOptimized`, `StorageOptimized`, `GpuAccelerated`, `FpgaAccelerated`, `HighPerformanceCompute` |
| `architecture` | string | any | `x64`, `Arm64` |
| `burstable` | string | any | `Excluded`, `Required` |
| `confidential_computing` | string | any | `Excluded`, `Required` |
| `family_allowlist` | list | all | Azure family names, for example `standardEdsv6Family`. |
| `family` | string | none | One Azure family name. |
| `placement.type` | string | `regional` | `regional`, `zonal`, `zone_redundant` |
| `placement.zones` | list | none | Zone numbers. Required when `type` is `zonal`. |
| `placement.zone_count` | number | `3` | Used when `type` is `zone_redundant`. |

Three fields narrow the candidate families. The most specific one wins:

1. `family` selects one family. It overrides everything below.
2. `family_allowlist` limits the candidates to a list.
3. `category` and the attribute fields filter by shape.

`placement.type` is not a preference. It decides which families are eligible.
Azure grants zone access for each SKU size and each zone separately.

The application team states a category. It does not state a VM family. A person
who fills in a subscription request is not expected to know Azure family names.

### Fields APE reads from outside `compute:`

| Field | Used for |
|---|---|
| `subscription.environment` | Selects which business rule applies. |

### Full example

```yaml
compute:
  region: eastus
  vcpus: 64
  category: MemoryOptimized
  architecture: x64
  burstable: Excluded
  placement:
    type: zone_redundant
    zone_count: 3
```

[`examples/vending-stage-2/intake.example.yaml`](../examples/vending-stage-2/intake.example.yaml)
shows the `compute:` block inside a complete parameter file.

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

Bicep cannot read quota state. On this path PowerShell does the read and the
decision. Bicep does the write.

```mermaid
flowchart LR
    T1[ape-read] --> T2[ape-placement] --> T3[ape-apply]
    B1[ApeRead.psm1] --> B2[ApePlacement.psm1] --> B3[ape-apply.bicepparam] --> B4[ape-apply.bicep]
```

The top row is Terraform. The bottom row is the Bicep path. PowerShell does the
read and the decision. Bicep does only the write.

Both rows must give the same answer. The scenarios in `conformance/scenarios`
test each one.

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

Rules belong to the platform team, not to the requester. They are set in the
module call, not in the intake.

APE evaluates rules in order and uses the first one whose `environments`
matches. A rule with no `environments` matches every request, so put it last.

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

APE applies four gates, in this order.

```mermaid
flowchart LR
    A[1. Region] --> B[2. Lifecycle] --> C[3. Access] --> D[4. Quota] --> E[Decision]
```

| Gate | Question | Failure status |
|---|---|---|
| 1. Region | Can the subscription reach the region? | `not_ready`, `blocked_by_region` |
| 2. Lifecycle | Is any candidate family still open to new subscriptions? | `blocked_by_lifecycle` |
| 3. Access | Can the subscription deploy any candidate here? | `blocked_by_access` |
| 4. Quota | Can any candidate reach the requested size? | `needs_increase`, `infeasible` |

A gate means nothing until the gates above it pass. Quota and access are
separate. A quota group grants no regional access and no zonal access. Quota for
a family the subscription cannot deploy is therefore useless. APE checks access
first.

A business rule can reject the request before any gate runs. That gives
`blocked_by_rule`.

Use `status` to decide what to do next.

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

### Choosing runners

Two repository variables set `runs-on`. Leave them unset and the workflows use
GitHub-hosted runners. Set them and the jobs run on your own machines.

| Variable | Unset | Set |
|---|---|---|
| `CI_RUNNER_LINUX` | `ubuntu-latest` | that label — Terraform and Bicep jobs |
| `CI_RUNNER_WINDOWS` | `ubuntu-latest` | that label — PowerShell jobs |

The PowerShell jobs need `pwsh`. The Bicep job needs the Azure CLI. Point
`CI_RUNNER_WINDOWS` at a machine with PowerShell. Point `CI_RUNNER_LINUX` at a
machine with `az`.

> **Self-hosted runners cannot be shared between repositories on a personal
> account.** Runner *groups*, the mechanism for sharing, exist only for
> organizations. A machine already running a runner for another repo can host a
> second, independent registration for this one — same machine, separate
> directory and service.

```bash
# Mint a registration token (expires in one hour)
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token -q .token
```

```bash
# On the runner machine, in a NEW directory beside the existing runner
./config.sh --url https://github.com/OWNER/REPO --token <TOKEN>   --name ape-ci-linux --labels ape-ci-linux --unattended
sudo ./svc.sh install && sudo ./svc.sh start
```

Then set the variable to the label you chose:

```bash
gh variable set CI_RUNNER_LINUX --body ape-ci-linux
```

> Do not set the variable before the runner is registered and online, or jobs
> queue waiting for a runner that does not exist.

A public repository gets unlimited GitHub-hosted minutes for standard runners.
If this repository becomes public, none of the above is needed.

### Reviewing before writing

Stage 2 plans against a subscription that already exists. The plan shows the
chosen family, the quota to write, and the reason each other family was
rejected. Review it in the pull request before anything is written.