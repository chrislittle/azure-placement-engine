# Architecture

**Status:** working draft — contracts settled, engine not yet built
**Related:** [`../../azure_next/VISION.md`](../../azure_next/VISION.md)

---

## What this is

The Azure Next thesis says the developer writes `hub: eu` and the platform decides
everything below it — service selection, placement, resilience, compliance. That
placement machinery is exactly what today's Azure does not have, and what every
customer therefore assembles by hand out of spreadsheets, region-availability
pages, quota tickets and tribal knowledge.

This engine is **that machinery, retrofitted onto today's regional Azure**. It
takes a normalized statement of what a workload needs and returns a ranked,
evidenced, reproducible region placement.

**The input is an ancestor of `outcome.yaml`.** Same vocabulary as the thesis,
one abstraction level lower. Where the outcome file says `hub: eu`, the
requirements file says `residency.jurisdictions: [eu]` — and the engine *outputs*
the concrete regions.

**The output is the resolution record.** The thesis: *"on every release the
platform writes back what it chose ... developers can read it; they never edit
it."* That is precisely the decision record.

### What this is not

An **advisory plane, not a control plane.** It decides and explains. It can
*emit* enforcement artifacts — an Azure Policy `allowedLocations` assignment,
deployment parameters, landing-zone configuration — but it does not own placement
the way a Sovereign Hub would. We cannot change Azure fundamentally; we can
remove the part of the job that should never have been the customer's.

---

## Grounding: CAF for the criteria, WAF for the structure

Neither of these was invented here, and that matters — a placement recommendation
that cites Microsoft's own guidance is arguable on its merits, while one built on
private criteria is just an opinion with a score attached.

### CAF supplies the criteria

[Select Azure regions](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-setup-guide/regions)
prescribes four steps: check data residency and compliance → choose regions close
to your users → validate region capabilities (service availability, pricing,
availability zones, region pairs, **capacity constraints**) → consider multiple
regions. Every hard filter and every weight in this engine maps to one of them.

Two consequences worth recording, because both corrected earlier guesses:

- **Sustainability is not a CAF criterion.** It appears nowhere in the region
  guidance. It was cut.
- **Region pairing is explicitly de-emphasized.** CAF now states that favouring
  paired regions *"is no longer mandatory"* and that regions should be chosen on
  latency, compliance and resiliency needs. So `require_paired_region` defaults
  off and exists only for services that genuinely depend on pairing, or a standing
  customer mandate.

CAF is a **sequenced checklist, not a scoring model** — it never says how to rank
the regions that survive. The weighting is therefore ours, and the decision record
says so rather than implying Microsoft prescribed it.

### WAF supplies the structure

The requirements schema is built around **flows**, a defined Well-Architected
concept: *"the sequence of actions that performs a specific function... the
movement of data and the running of processes between components of the
workload."* WAF already asks customers to inventory them, rate their criticality,
and attach RTO/RPO to each —
[RE:02](https://learn.microsoft.com/en-us/azure/well-architected/reliability/identify-flows)
for reliability,
[CO:09](https://learn.microsoft.com/en-us/azure/well-architected/cost-optimization/optimize-flow-costs)
for cost, the latter listing a flow's attributes as latency sensitivity, data
dependencies, security needs, and compliance requirements.

Adopting flows resolved four separate design problems at once:

| Problem | How flows solve it |
|---|---|
| Co-location | **Derived, not declared.** A latency-sensitive high-criticality flow wants its path together. |
| Per-component topology | **Derived.** A component inherits the strictest RTO/RPO among the flows it serves — so a reporting store on a 24-hour flow never pays for active-passive. |
| Per-component residency | **Inherited down the path.** A flow carrying regulated data imposes its envelope on every component it touches. |
| Over-constrained inputs | **Criticality says what to sacrifice.** The engine returns priced relaxations instead of "infeasible". |

Where a customer has no flow inventory, `effective_flows()` synthesises a single
implicit flow over every component, so the fallback degrades gracefully.

---

## Pipeline

```
requirements.yaml
      │
      ▼
[1] Normalize ──── validate, resolve flow inheritance, digest the input
      │
      ▼
[2] Resolve ────── ARM resource types (+ archetypes where unchosen) → required capabilities
      │
      ├──◀── world snapshot   (pinned, versioned, public facts)
      ├──◀── tenant context   (live or offline, customer-specific facts)
      │
      ▼
[3] Constrain ──── CAF hard filters → candidate regions       ──▶ eliminations[]
      │
      ▼
[4] Compose ────── derive per-component topology from flow RTO/RPO; build region sets
      │
      ▼
[5] Score ──────── weighted ranking of survivors               ──▶ subscores + evidence
      │
      ▼
[6] Record ─────── winner, alternatives, eliminations, flow outcomes, risks, relaxations
      │
      ▼
[7] Emit ───────── report · policy · IaC params · diff-vs-previous
```

Stages 3–5 are strictly separated because they carry different burdens of proof.
A **hard constraint** must be defensible from a deterministic fact ("this
capability is not in this region"). A **score** is a judgement under a declared
weighting, and is allowed to be arguable. Collapsing the two produces a tool
nobody trusts, because a customer cannot tell whether their region lost on fact
or on opinion.

---

## Two data planes

Separated because they differ in trust, freshness, and blast radius.

### World snapshot — public, pinned, versioned

Ingested from real Azure sources, materialised as a versioned snapshot, and
**pinned into every decision record**. Snapshots are committed: they are the
reproducibility guarantee, not a cache.

| Fact | Source | Signal quality |
|---|---|---|
| Regions, geography, paired region, **region category** | ARM `locations` API (`metadata.pairedRegion`, `geographyGroup`, `regionCategory`) | Deterministic |
| Availability-zone support & zone mappings | ARM `locations` API, `Microsoft.Compute/skus` | Deterministic |
| Service availability by region | ARM provider metadata (`resourceTypes[].locations`) | Deterministic |
| **Capability**-level availability | Per-RP capability APIs (e.g. `Microsoft.DBforPostgreSQL/locations/{loc}/capabilities`); ~80 `reliability-*` doc pages for the rest | Deterministic, **fragmented** |
| VM SKU availability & capabilities | `Microsoft.Compute/skus` | Deterministic |
| Retail pricing | Retail Prices API (public, unauthenticated) | Deterministic |
| Inter-region & origin latency | [Azure network round-trip latency statistics](https://learn.microsoft.com/en-us/azure/networking/azure-network-latency) | Measured, monthly |
| Residency boundaries, sovereign clouds | EU Data Boundary docs, cloud endpoint metadata | Curated |
| Compliance certification scope | Trust Center — **service-scoped, not only region-scoped** | Curated |

### What the first real ingest changed

Running ingester #1 against a live subscription (109 locations, 63 physical)
corrected three things that a fixture built from assumption had wrong. Recorded
here because each is a trap the next ingester could fall into too.

**Internal regions come back looking like real ones.** `eastus2euap` is
`Physical`, category `Recommended`, and reports **four availability zones** —
more than any production region. Unfiltered, it would have outscored every real
region and been recommended to a customer. Two shapes exist: `*euap` and `*stg`
are `Physical` and need an explicit production filter, while `*stage` regions
come back `Logical` and are already excluded. Hence `placement_candidates()`,
which is the only region set the engine may ever recommend from. Internal regions
are *marked, not dropped* — the snapshot stays a faithful record of what ARM
returned, and the CLI reports what it excluded on every build.

**`geography` is the residency boundary, not the country.** `westeurope` reports
`geography: "Europe"` and `physicalLocation: "Netherlands"`. That is not a data
quirk — Azure's residency commitment genuinely is Europe-wide for that region,
while `germanywestcentral` reports `geography: "Germany"`. So residency filters
must use `geography`; filtering a country requirement on `physicalLocation` would
promise something Microsoft does not commit to.

**Most new European regions have no paired region at all** — `austriaeast`,
`belgiumcentral`, `denmarkeast`, `italynorth`, `polandcentral`, `spaincentral`.
Had `require_paired_region` defaulted on, the engine would have silently
eliminated six modern EU regions. Direct confirmation of CAF's shift away from
mandatory pairing, and of the decision to default it off.

One consequence worth flagging early, visible in the data before the solver
exists: the `eu-residency` scenario asks to stay in Germany with three
availability zones and a four-hour RTO. The German geography contains exactly two
regions, and `germanynorth` has **no availability zones**. There is no in-country
secondary that satisfies the constraints — which is precisely the case
`relaxations` exists to answer rather than returning "infeasible".

### What the service-availability ingest changed

Provider metadata (`resourceTypes[].locations`) is the first slice that can
eliminate a region for a reason a customer recognises. Two things about the real
payload matter.

**Locations are display names in inconsistent casing** — a single live response
contained `'Uk West'`, `'italy north'`, `'spain central'`, `'SouthEast Asia'`,
`'Norway EAST'`, `'Central Us'`, `'japan East'`. Squeezing whitespace and
lowercasing turns `"Italy North"` into `italynorth`, which *is* the ARM region
name, so that normalisation is the join key. A few strings are geographies rather
than regions (`'UAE'`, `'UK'`) and resolve to nothing; they are recorded as
unmapped in the source note rather than silently dropped.

**This slice is partly shaped by the collecting subscription, and that is a real
limitation.** Azure's [restricted-access
regions](https://learn.microsoft.com/en-us/troubleshoot/azure/general/region-access-request-process)
— Germany North, France South, Norway West and similar — need a support request
to use, and provider metadata reflects that unevenly: against a live
subscription, `Microsoft.ContainerService/managedClusters` listed Germany North
while `Microsoft.Storage/storageAccounts` did not. So **absence from the provider
list is a strong signal, not proof.** Capability-level ingest (#3) is what turns
it into per-region truth for the services that actually matter.

Rather than bury that, it is exposed as `service_coverage(region)` — the fraction
of regionally-deployable resource types present in a region. Against real data it
separates cleanly:

| Region | Coverage | Category |
|---|---:|---|
| westeurope | 89.5% | Recommended |
| germanywestcentral | 70.9% | Recommended |
| italynorth | 59.7% | Recommended |
| belgiumcentral | 39.8% | Recommended |
| switzerlandwest | 27.3% | Other |
| germanynorth | 18.9% | Other |

That is a **better maturity signal than `regionCategory`**, which is only ever
Recommended or Other: `denmarkeast` and `westeurope` are both "Recommended" while
differing by more than 50 points of actual service coverage. The
`region_category` weight should be computed from coverage, with the ARM category
as a secondary input.

A low-coverage region means *either* a genuinely thin region *or* one this
subscription cannot see. Both must reach the reader before they act, so it
belongs on the candidate as a risk either way.

### Tenant context — customer-specific

Two collection modes, same schema. **Offline** (default) is a JSON export —
portable, no credentials, works in a customer meeting, reviewable before use, and
not committed. **Live** is a read-only ARM collector.

| Fact | Source |
|---|---|
| `allowedLocations` policy assignments | Policy API — becomes a **hard whitelist** |
| Existing footprint (regions, subscriptions, MGs) | Azure Resource Graph |
| Quota limits and current usage | Quota API / usages |
| Subscription-specific SKU restrictions | `Microsoft.Compute/skus` `restrictions[]` |
| Spot placement scores | `Microsoft.Compute/locations/{loc}/placementScores/spot` |
| Network anchors (ER peering locations, vWAN hubs) | Resource Graph |

---

## The three hard problems

### 1. Capacity is not queryable

CAF names capacity as a region-selection criterion but there is no Azure API that
answers *"does swedencentral have room for 64 × ND96isr H100 v5?"* The available
signals are indirect: SKU `restrictions` (subscription-specific and authoritative
**for exclusion**), quota headroom, and spot placement scores.

So capacity splits in two: a **hard elimination where we have proof** — a
restriction on your subscription is a fact — and a **scored confidence with
evidence below 1.0** everywhere else. It is never asserted as a boolean. This
mirrors the thesis's honest GPU caveat: *"no architecture invents metal."* An
engine that implies certainty it does not have is worse than no engine, because
the first allocation failure destroys trust in every other output too.

`Evidence.confidence` exists for exactly this: deterministic facts carry 1.0,
inferred capacity signals do not, and the record shows the difference.

### 2. Capability data is fragmented, not missing

An earlier draft of this document claimed you can't tell whether a service
supports zone redundancy in a region. That was wrong and is corrected here,
because the distinction changes what the engine is for.

The data *is* documented. What it isn't is **in one place at the granularity a
placement decision needs**. [Azure Services That Support Availability
Zones](https://learn.microsoft.com/en-us/azure/reliability/availability-zones-service-support)
has three columns — Service, Zone-redundant, Zonal — and **no region column**; it
tells you a service supports AZs *somewhere*. The page says so itself: *"some
services might support availability zones for only specific tiers or regions"*,
pointing at ~80 individual service reliability guides. Meanwhile some RPs expose
a proper capabilities API and others don't, and subscription-specific
restrictions aren't documented anywhere because they're per-tenant.

So the engine's job here is **aggregation, not discovery** — and the thing it adds
that no doc page can is answering the question *as of a fixed date*, which is what
makes a recommendation auditable.

Coverage will be uneven. **Unknown ≠ available:** a capability the snapshot cannot
confirm produces a risk on the surviving candidate, never a silent pass.

### 3. Freshness fights reproducibility

Pinning resolves it. Every decision record carries the snapshot version and
per-source as-of dates, so partial staleness is visible. Re-running against a
newer snapshot produces a **diff** — *"westeurope is no longer eliminated:
Postgres zone-redundant HA shipped 2026-07"* — which is arguably worth more than
the original answer.

---

## Scoring model

Five weights, each traceable to a CAF criterion:

| Weight | CAF criterion |
|---|---|
| `latency` | Choose regions close to your users |
| `cost` | Compare pricing |
| `capacity_confidence` | Plan for capacity constraints (the inferred part; proven restrictions eliminate) |
| `region_category` | Azure's own Recommended vs Alternate classification |
| `landing_zone_expansion` | The [landing-zone region guidance](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/considerations/regions): a new hub or vWAN hub in the Connectivity subscription, gateways, DNS forwarders, identity expansion, workspace placement |

Weights are the customer's risk posture made explicit — the GPU scenario weights
capacity at 0.50, the landing-zone scenario weights expansion at 0.35.
**Publishing the weights alongside the answer is what makes the answer arguable
rather than oracular.**

### Deterministic core; LLMs only at the edges

Filtering and scoring are deterministic and reproducible, because a placement
decision gets challenged in a design review and has to survive being re-run. LLMs
earn their place at three edges, none of which touch ranking: **intake** (prose or
a diagram → a validated requirements file), **curation** (documentation →
structured facts, with a human-reviewable diff), and **narration** (a decision
record → the paragraph a customer reads).

---

## Output

**The answer is a topology, never a bare region.** A workload with a
five-minute-RTO flow has no meaningful single-region answer.

Every candidate carries three views: region-centric (`placements` — what lands
where), component-centric (`components` — the **derived** topology per component
and which flow drove it), and flow-centric (`flows` — whether each flow got split,
what latency and egress that cost, whether its RTO/RPO is met).

Every **elimination** records the rule that fired and the fact that proved it,
because *"why not region X"* is the question that actually gets asked.

And when nothing fits, the record carries **relaxations** rather than an error:
*"nightly-reporting is low-criticality — split it to westeurope and everything
else fits in germanywestcentral."* That is what flow criticality buys, and it is
the difference between advice and an error message.

---

## Decisions taken

| # | Decision |
|---|---|
| 1 | Residency declarable at workload, flow, and component level; a component's effective envelope is the intersection |
| 2 | **Topology is an engine output**, derived from flow RTO/RPO, with a per-component override for standing mandates |
| 3 | `horizon` + per-component `growth` are scored. Commitment lock-in is **not** modelled — Azure savings plans apply across regions and families, so commitment is placement-neutral, and RIs are declining |
| 4 | Capability data shape follows the sources; deferred until the first capability ingester exists rather than guessed at |
| 5 | **ARM resource type is the primary way to name a component**; archetypes are the optional "help me choose" path |
| 6 | Five weights, all CAF-traceable. Sustainability cut. Region pairing de-emphasized per current CAF |
| 7 | **WAF flows are the structural core**, with an implicit single-flow fallback |

---

## Build order

The four scenarios in [`../scenarios/`](../scenarios/) are the **acceptance set,
not a roadmap** — each stresses a different constraint family, and the engine
needs all four in the model from the start:

| Scenario | Stresses |
|---|---|
| `gpu-training` | Capacity confidence, SKU availability, an unsplittable flow |
| `eu-residency` | Residency & compliance filters, two flows with different RTOs in one workload |
| `three-tier` | Many services, split global demand, flows of differing criticality |
| `lz-expansion` | Tenant context, policy whitelist, landing-zone expansion cost |

What *is* sequenced is the **data ingesters, in descending order of signal
quality** — deterministic facts first, inferred signals last:

1. Region metadata, geo-pairs, AZ support, **region category** — deterministic, small, high leverage
2. Service availability by region — deterministic
3. Capability-level data — deterministic, fragmented
4. Pricing — deterministic, large
5. Latency matrix — measured
6. Residency / compliance — curated
7. **Capacity signals — inferred, last**

Capacity comes last deliberately. If the deterministic layers cannot be trusted
first, a probabilistic layer on top of them is unfalsifiable.
