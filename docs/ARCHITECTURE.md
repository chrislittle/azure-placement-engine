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

### What the capability ingest settled

This is the slice that answers decision #4, deferred during scoping because the
shape had to follow the data. Having now seen three sources, the answer is that a
capability is **neither a free string nor a typed field — it is a named rule with
a source-specific resolver**:

| Capability | Resolved from | Shape |
|---|---|---|
| `availability-zones` | the region table | zone count, no API call — **topology, not deployability** |
| `zone-redundant-storage`, `geo-redundant-storage`, `premium-block-blob` | `Microsoft.Storage/skus` | encoded in **SKU names** (`Standard_ZRS`, `Standard_GZRS`) |
| `zone-redundant-ha`, `geo-backup` | `Microsoft.DBforPostgreSQL/locations/{loc}/capabilities` | explicit flags, **one call per region** |

The requirements file names the capability; the ingester knows how to resolve it.
Everything else stays `None` — unknown, a risk on the surviving candidate, never
an elimination. Coverage is uneven by nature, since most resource providers
expose no capabilities API at all.

**Having zones is not the same as being able to deploy zonally.** The locations
API reports physical topology; it cannot say whether new zonal deployments are
currently being accepted. The two visibly diverge in the snapshot: `westeurope`
reports three availability zones *and* reports no zone-redundant HA for Postgres.
So the region-derived `availability-zones` capability is a **necessary condition,
never a sufficient one** — where a service-specific zonal capability exists it is
the authority and must be checked as well, and where none exists the residual
uncertainty belongs on the candidate as a risk.

**The API can be more current than the docs, and wins.** `westeurope`
reports `zoneRedundantHaSupported: Disabled` despite having three availability
zones — which looks wrong until you read the [Postgres regions
table](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/overview),
which marks West Europe as supported **but** annotated *"new zone-redundant HA
deployments are temporarily blocked"*. The API reports what can be deployed
today; the docs table reports nominal support. A placement engine is deciding
where to deploy **now**, so the API is the authority and is deliberately allowed
to disagree.

That single fact reshapes the `eu-residency` scenario against live data:

| German region | All services | Zone-redundant HA | Zones |
|---|---|---|---|
| `germanywestcentral` | yes | yes | 3 |
| `germanynorth` | no | no | 0 |

So `germanywestcentral` is the only viable region in the German geography, and
there is **no in-country secondary at all** — confirmed from real data rather
than assumed. Exactly the case `relaxations` exists to answer.

### A digest that survives schema growth

Adding the capability slice broke every previously written snapshot's digest —
an empty `capabilities: {}` changed the hash of content that had not changed.
That is backwards: the digest exists to prove *content* is unchanged, so a schema
addition must not retroactively invalidate it. `canonical()` now strips empty
collections as well as nulls, so a new slice is invisible to snapshots that do
not use it, while populating one still changes the hash.

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

### What the VM SKU ingest made answerable

`Microsoft.Compute/skus` is the largest source by far — ~230 MB unfiltered, ~4.8 MB
and 1300 SKUs per region — so it is collected per region and projected hard.
199 MB of payloads become 3.6 MB of snapshot: 1477 SKUs, of which 51 carry
accelerators and 40 are RDMA-capable.

**SKU zones are much finer than region zones, and the difference is decisive.**
`Standard_ND96isr_H100_v5` is offered in `swedencentral` zone 1 only,
`westeurope` zone 3 only, `italynorth` zone 2 only. All three are three-zone
regions. Any zone-redundant design for that SKU is impossible in them, and the
region-level zone count hides that completely.

**The same payload feeds both planes, and splitting it is what makes the answer
useful.** SKU identity, capabilities and zones are world facts. `restrictions[]`
— 6179 entries across 48 regions on the test subscription, every one
`NotAvailableForSubscription` — describes what *this* subscription may deploy, so
it goes to tenant context. For the GPU scenario, in Europe:

| | Regions |
|---|---|
| Offer the H100 SKU | `italynorth`, `norwayeast`, `polandcentral`, `swedencentral`, `westeurope` |
| Deployable on this subscription today | `italynorth`, `norwayeast` |
| A support request away | `polandcentral`, `swedencentral`, `westeurope` |

Neither plane alone gives a usable answer. The world snapshot says five regions
and would send the customer at a deployment that fails. Tenant context alone says
two and would send them to a worse region than they could have had. **The
recommendation is two, with three named as requestable** — and that only exists
because the two planes are kept apart and then compared.

The restriction ratio also identifies access-restricted regions without a curated
list: `uaecentral` 59%, `brazilsoutheast` 48%, `jioindiacentral` 47%, against
under 10% for ordinary regions.

### Access and quota are two different gates

A correction to the slice above, and an important one: **an absent SKU restriction
does not mean you can deploy.** Quota is a separate gate, and for GPU families it
is the one that actually bites. On a live subscription, `Microsoft.Compute/locations/{region}/usages`
reported **22 of 28 GPU families with a vCPU limit of zero** in West Europe — and
so did ordinary families like `standardDSv5Family`. Zero quota is the common case
on a subscription without history, not an edge case.

So deployability is three independent conditions, each with its own remedy:

| Condition | Source | If it fails |
|---|---|---|
| The SKU exists in the region | world snapshot | nothing to request |
| The subscription is not restricted from it | tenant `restrictions[]` | region / zonal access request |
| There is quota for its family | tenant `usages` | quota increase |

Order matters: access is checked first, because **you cannot raise quota in a
region you have no entitlement to** — reporting the quota remedy there would send
someone to file the wrong ticket.

This is the same mistake as the availability-zones one, in a different costume.
`is_unrestricted()` is deliberately named to say what it checks: a **necessary,
not sufficient** condition. `assess()` is the question people actually mean, and
it returns the failing condition and its remediation rather than a bare boolean.

The join between the two APIs needs normalising — the SKU list says
`standardNDSH100v5Family` while usages says `Standard NCASv3_T4 Family`, so both
sides are squeezed and lowercased. That matches 183 of 184 families against live
data. Regional totals (`cores`, `lowPriorityCores`) are kept but flagged, since a
per-family quota is meaningless if the regional cap is already exhausted.

### Not every elimination is final

Azure region and zonal access are **not open by default**. A number of regions
are access-restricted, and zonal or service access in others — database services
notably — is gated behind a quota request. These are ordinary, routinely granted
support requests, not dead ends.

That makes "unavailable" the wrong word for a large class of results, and the
error is expensive in the direction that matters: a customer told a region is
unavailable will settle for a worse one rather than raise a ticket that would
have succeeded.

So an `Elimination` can carry a **`Remediation`** — the concrete action that
would lift it, with the documented process attached:

| Kind | Meaning |
|---|---|
| `region-access-request` | Reserved/restricted region; access requestable via support |
| `zonal-access-request` | Region reachable but zonal deployment not enabled |
| `quota-increase` | Available, but current quota is insufficient |
| `none` | Genuinely unavailable; nothing to request |
| `unknown` | May be requestable; not established |

For restricted regions the process is a support request with issue type *Service
and subscription Limit (quotas)* and quota type *Other Requests*, describing the
region, deployment model and planned quota — see the [region access request
process](https://learn.microsoft.com/en-us/troubleshoot/azure/general/region-access-request-process).
The record carries that text so the reader can act on it without a second search.

**Remediation and relaxation are different things**, and the record keeps them
apart. A *remediation* changes the customer's Azure entitlements and leaves the
design intact — request the region, raise the quota. A *relaxation* changes the
requirements — split a low-criticality flow, drop an optional capability. One is
a ticket; the other is a design concession, and the customer should be offered
the ticket first.

This also settles where the signal comes from, and it falls out of the two-plane
split cleanly. The **world snapshot** records what exists. The **tenant context**
records what this subscription can reach — the Postgres capabilities API's
`restricted` flag, `Microsoft.Compute/skus` restrictions, quota headroom. The gap
between the two *is* the remediation: something that exists but is not yet
reachable is a request, not an absence. That is precisely why subscription-scoped
fields are kept out of the world snapshot rather than merged into it.

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
