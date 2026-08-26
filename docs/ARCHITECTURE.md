# Architecture

**Status:** working draft — scoping settled, engine not yet built
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

Two structural consequences follow, and both are load-bearing:

**The input is an ancestor of `outcome.yaml`.** Same vocabulary as the thesis,
one abstraction level lower. Where the outcome file says `hub: eu`, the
requirements file says `residency.jurisdictions: [eu]` — and the engine
*outputs* `swedencentral` + `westeurope`. A requirements file can be
mechanically derived from an outcome file, which gives the tool a migration path
instead of a throwaway schema.

**The output is the resolution record.** The thesis: *"on every release the
platform writes back what it chose ... as a queryable record ... developers can
read it; they never edit it."* That is precisely the decision record.

### What this is not

An **advisory plane, not a control plane.** It decides and explains. It can
*emit* enforcement artifacts — an Azure Policy `allowedLocations` assignment,
deployment parameters, landing-zone configuration — but it does not own
placement the way a Sovereign Hub would. We cannot change Azure fundamentally;
we can remove the part of the job that should never have been the customer's.

---

## Pipeline

```
requirements.yaml
      │
      ▼
[1] Normalize ──── validate, resolve defaults, digest the input
      │
      ▼
[2] Resolve ────── outcome archetypes → concrete Azure services + required features
      │
      ├──◀── world snapshot   (pinned, versioned, public facts)
      ├──◀── tenant context   (live or offline, customer-specific facts)
      │
      ▼
[3] Constrain ──── hard filters → candidate regions          ──▶ eliminations[]
      │
      ▼
[4] Compose ────── candidate regions → viable topologies (pairing, affinity, AZ)
      │
      ▼
[5] Score ──────── weighted multi-objective ranking          ──▶ subscores + evidence
      │
      ▼
[6] Record ─────── DecisionRecord: winner, alternatives, eliminations, risks
      │
      ▼
[7] Emit ───────── report · policy · IaC params · diff-vs-previous
```

Stages 3–5 are strictly separated because they answer different questions and
have different burdens of proof. A **hard constraint** must be defensible from a
deterministic fact ("this service is not in this region"). A **score** is a
judgement under a declared weighting, and is allowed to be arguable. Collapsing
the two produces a tool nobody trusts, because a customer cannot tell whether
their region lost on fact or on opinion.

---

## Two data planes

They are separated because they differ in trust, freshness, and blast radius.

### World snapshot — public, pinned, versioned

The rubric. Ingested from real Azure sources, materialised as a versioned
snapshot, and **pinned into every decision record**. Snapshots are committed to
the repo: they are the reproducibility guarantee, not a cache.

| Fact | Source | Signal quality |
|---|---|---|
| Regions, geography, paired region, region category | ARM `locations` API (`metadata.pairedRegion`, `geographyGroup`, `regionCategory`) | Deterministic |
| Availability-zone support & zone mappings | ARM `locations` API, `Microsoft.Compute/skus` | Deterministic |
| Service availability by region | ARM provider metadata (`resourceTypes[].locations`); products-by-region as cross-check | Deterministic |
| **Feature**-level availability | Per-service capability APIs (e.g. Postgres Flexible `locations/{loc}/capabilities`, AKS, Cosmos, Storage) | Deterministic, uneven coverage |
| VM SKU availability & capabilities | `Microsoft.Compute/skus` (`locations`, `zones`, `capabilities`) | Deterministic |
| Retail pricing | Retail Prices API (public, unauthenticated) | Deterministic |
| Inter-region & origin latency | Azure network round-trip latency statistics; optional client probing | Measured, monthly |
| Residency boundaries, sovereign clouds | EU Data Boundary docs, cloud endpoint metadata | Curated |
| Compliance certification scope | Trust Center / Service Trust Portal — **service-scoped, not only region-scoped** | Curated |
| Carbon / grid intensity | Regional sustainability data | Curated, coarse |

### Tenant context — customer-specific

The customer's actual reality. Two collection modes, same schema:

- **Offline** (default) — a JSON export. Portable, no credentials, works in a
  customer meeting, safe to review before use. Not committed (see `.gitignore`).
- **Live** — a read-only ARM collector against the customer's tenant.

| Fact | Source |
|---|---|
| `allowedLocations` policy assignments | Policy API — becomes a **hard whitelist** |
| Existing footprint (regions, subscriptions, MGs) | Azure Resource Graph |
| Quota limits and current usage | Quota API / usages |
| Subscription-specific SKU restrictions | `Microsoft.Compute/skus` `restrictions[]` — `NotAvailableForSubscription` |
| Spot placement scores | `Microsoft.Compute/locations/{loc}/placementScores/spot` |
| Network anchors (ER peering locations, vWAN hubs) | Resource Graph |

---

## The three hard problems

### 1. Capacity is not queryable

There is no Azure API that answers *"does swedencentral have room for 64 × ND96isr
H100 v5?"* The available signals are indirect: SKU `restrictions` (which **is**
subscription-specific and authoritative for exclusion), quota headroom, spot
placement scores, and spot price/eviction behaviour as a proxy for pressure.

So capacity is modelled as a **confidence score with cited evidence and an
explicit confidence below 1.0**, never as a boolean. This mirrors the thesis's
honest GPU caveat: *"no architecture invents metal."* An engine that implies
certainty it does not have is worse than no engine, because the first
allocation failure destroys trust in every other output too.

`Evidence.confidence` exists on every fact for exactly this reason: a
deterministic fact carries 1.0, an inferred capacity signal does not, and the
decision record shows the difference.

### 2. Granularity kills you

"Service X is available in region Y" is close to useless. Deployments break on
*features*: zone-redundant HA, customer-managed keys, a specific tier, a specific
GPU family, confidential nodes, preview scope. The data model is therefore
feature-granular from day one — `Component.features` is a first-class list, and
`FEATURE_AVAILABILITY` is its own elimination stage.

Coverage will be uneven, because the per-service capability APIs are uneven.
Unknown ≠ available: a feature the snapshot cannot confirm produces a **risk on
the surviving candidate**, not a silent pass.

### 3. Freshness fights reproducibility

Pinning resolves it. Every decision record carries the snapshot version and
per-source as-of dates, so partial staleness is visible. Re-running against a
newer snapshot then produces a **diff** — *"westeurope is no longer eliminated:
Postgres zone-redundant HA shipped 2026-07"* — which is arguably worth more than
the original answer, and is the feature that makes the tool something a customer
returns to rather than runs once.

---

## Scoring model

Six dimensions, each normalised 0–1, weighted by the caller's `priorities` block
(normalised, so relative magnitude is what matters):

| Dimension | What it measures |
|---|---|
| `latency` | Demand-share-weighted round-trip from declared demand origins |
| `cost` | Modelled monthly cost of the resolved service set at declared capacity |
| `capacity_confidence` | Aggregate confidence that the declared capacity is actually obtainable |
| `resiliency` | AZ count, geo-pairing, topology fit, blast-radius separation |
| `operational_fit` | Overlap with existing footprint and network anchors |
| `sustainability` | Regional carbon intensity |

The weights are the customer's risk posture made explicit. The GPU scenario
weights capacity at 0.50; the landing-zone scenario weights operational fit at
0.30. **Publishing the weights alongside the answer is what makes the answer
arguable rather than oracular** — the reader can disagree with the weighting
instead of disagreeing with the tool.

### Deterministic core; LLMs only at the edges

Constraint filtering and scoring are deterministic and reproducible, because a
placement decision gets challenged in a design review and has to survive being
re-run. LLMs earn their place at three edges, none of which touch ranking:

- **Intake** — prose or an architecture diagram → a validated requirements file.
- **Curation** — turning documentation into structured facts during ingest, with a human-reviewable diff.
- **Narration** — turning a decision record into the paragraph a customer reads.

---

## Output: the answer is a topology

Never a bare region. A workload declaring `active-passive` with
`geo_pair_required` has no meaningful single-region answer, and the failure mode
of pretending otherwise is a recommendation that cannot actually be built.

Every candidate carries its placements (region + role + which components land
there), its subscores with evidence, and its residual risks. And every
**elimination** is recorded with the rule that fired and the fact that proved it
— because *"why not region X"* is the question that actually gets asked, and
answering it is most of the tool's value.

An empty result is a legitimate answer: `recommended: null` with a complete
elimination list is the engine correctly reporting that the requirements are
unsatisfiable, which is a finding, not a failure.

---

## Build order

The four scenarios in [`../scenarios/`](../scenarios/) are the **acceptance set,
not a roadmap**. Each stresses a different constraint family, and the engine
needs all four families in the model from the start:

| Scenario | Stresses |
|---|---|
| `gpu-training` | Capacity confidence, SKU availability, accelerator interconnect |
| `eu-residency` | Residency & compliance hard filters, feature-level encryption |
| `three-tier` | Multi-service co-location, geo-pairing, split global demand |
| `lz-expansion` | Tenant context, policy whitelist, existing-footprint fit |

What *is* sequenced is the **data ingesters, in descending order of signal
quality** — deterministic facts first, inferred signals last:

1. Region metadata, geo-pairs, AZ support — deterministic, small, high leverage
2. Service availability by region — deterministic
3. Feature-level capability APIs — deterministic, uneven
4. Pricing — deterministic, large
5. Latency matrix — measured
6. Residency / compliance — curated
7. **Capacity signals — inferred, last**

Capacity comes last deliberately. If the deterministic layers cannot be trusted
first, a probabilistic layer on top of them is unfalsifiable.
