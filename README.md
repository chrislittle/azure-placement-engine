# Azure Placement Engine

*(name is a placeholder)*

Layers quota and capacity decisions onto **Azure subscription vending**.

A vending module builds the subscription as normal. APE then reads the subscription request
that drove it and sets the subscription up to actually run something: allocating
vCPU quota, choosing a VM family when the customer has not fixed one, and
enforcing the platform team's business rules about who gets what.

It runs as a **second stage** after vending, taking the new `subscription_id` as
its only handoff. Microsoft's [subscription vending
guidance](https://learn.microsoft.com/en-us/azure/architecture/landing-zones/subscription-vending)
lists five deployment tasks: identity, governance, networking, budgets and
reporting. Quota is not one of them. The Cloud Adoption Framework states the
problem but does not solve it: *"the quota request can fail, so you should run a
script to handle any errors."*

```mermaid
flowchart LR
    C[("Subscription<br/>parameter file")] --> S1
    subgraph S1 ["STAGE 1 — vending"]
        D["avm-ptn-sub-vending"]
    end
    S1 -- "subscription_id" --> S2
    subgraph S2 ["STAGE 2 — APE"]
        direction LR
        E["ape-read"] --> F["ape-placement"] --> G["ape-apply"]
    end
    S2 --> H["application team"]

    style S1 fill:#eef4fb,stroke:#5b8db8
    style S2 fill:#eefbf2,stroke:#4a9d6a
    style C fill:#fdf6e3,stroke:#b58900
```

Two paths, one set of answers:

| | read | decide | apply |
|---|---|---|---|
| **Terraform** | `modules/ape-read` | `modules/ape-placement` | `modules/ape-apply` |
| **Bicep** | `powershell/ApeRead.psm1` | `powershell/ApePlacement.psm1` | `bicep/ape-apply.bicep` |

Bicep cannot read quota state, so on that path PowerShell reads and decides and
Bicep only writes. The decision logic therefore exists twice, and
[`conformance/`](conformance/) is what stops the two drifting — one set of
scenarios both must pass.

Built as Terraform and Bicep (AVM) modules. It composes with
[`Azure/avm-ptn-sub-vending/azurerm`](https://registry.terraform.io/modules/Azure/avm-ptn-sub-vending/azurerm/latest)
and [`avm/ptn/lz/sub-vending`](https://github.com/Azure/bicep-registry-modules/tree/main/avm/ptn/lz/sub-vending).
Neither of those handles quota. That is the gap APE fills.

APE has no service and no state of its own. Azure's APIs are the source of
truth. The modules read, decide and write.

**[Read the manual](docs/GUIDE.md)** — how to run it, what the answers mean,
where it slots into vending, and the GitHub Actions to wire it up.

## Status

Read, decide and apply are built and working against live subscriptions, in both
Terraform and Bicep. A previous Python implementation ranked regions and
recommended placements for a human to act on; it is superseded and not
published.

- [x] `ape-placement` — decides. 47 tests, no subscription needed
- [x] `ape-read` — live quota, SKU availability and region access, all Terraform
- [x] `ape-apply` — write quota, with the refusal semantics documented
- [x] `examples/vending-stage-2` — the handoff contract and a sample request
- [x] Bicep path — PowerShell read/decide, `ape-apply.bicep` write, 23 shared scenarios

## Shape

Three layers, deliberately kept distinct:

| Layer | Azure resource | What it is |
|---|---|---|
| **Quota quota** | `Microsoft.Quota/groupQuotas` | The right to ask. Costs nothing, guarantees nothing. Allocating from the group to a subscription is fast; raising the group limit is not. |
| **Capacity reservation** *(later)* | `Microsoft.Compute/capacityReservationGroups` | Held, guaranteed hardware. Costs money while idle. Declared by the customer, not sized by the tool. |
| **Vended subscription** | | The consumer. |

The quota stack owns the allocation table; vending configurations only read it. A
**reallocation** — transferring unused quota from member subscriptions,
and redistributing it — is not a separate lifecycle, it is what the quota stack
does when applied with updated floors and demands.

The decision module holds **no resources** — inputs to outputs, so it is testable
with fixtures and no subscription. Reading quota state, deciding, and writing are
separate concerns.

## Scope

**v1 is quota only.** The capacity reservation is a second layer, deferred until the
first is proven. It depends on a preview feature. A capacity reservation also
binds to one exact VM size, which does not suit a request that states only a
category.

The quota backend is swappable. Per-subscription `Microsoft.Quota` works today
and can be tested on an ordinary subscription. Quota groups change where the
unused comes from, not how the decision is made.

## Layout

| Path | What |
|---|---|
| `modules/ape-read/` | Reads live Azure state — quota, SKUs, region access |
| `modules/ape-placement/` | Decides. No resources, so it tests against fixtures |
| `modules/ape-apply/` | Writes the quota a decision asked for |
| `powershell/` | The same read and decide, for the Bicep path |
| `bicep/` | `ape-apply.bicep` — the Bicep half of the Bicep path |
| `conformance/` | One set of scenarios both implementations must pass |
| `docs/GUIDE.md` | The manual |
| `.github/workflows/` | Conformance, and stage 2 for both paths |
| `examples/vending-stage-2/` | The stage-2 pattern, with a sample request |
| `knowledge/` | Curated facts no API returns — dated and sourced |

## Known constraints

Verified against Microsoft docs, September 2026:

- Quota groups require an **EA, MCA, or Internal** billing account, cover **IaaS
  compute only**, and need `GroupQuota Request Operator` on the management group.
  A subscription can belong to **one quota group at a time**.
- Shared capacity reservation groups are **Preview**, cap at **100 consumer
  subscriptions**, and require the VM to match reservation size, region and zone
  exactly.
- Logical availability zones map differently per subscription, so deploying into
  a shared zonal reservation requires remapping or it fails.
- A shared reservation holds quota **twice** — once in the provider subscription
  for the reservation, once in the consumer subscription for the VMs.
