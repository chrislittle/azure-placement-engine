# Azure Placement Engine

*(name is a placeholder)*

Decides **where on Azure a workload should run** — region, topology, and why —
from a normalized statement of what the workload needs.

Feed it requirements; get back a ranked set of viable region topologies, each
with weighted subscores, cited evidence, residual risks, and a complete record
of why every other region lost.

```
requirements.yaml  ──▶  engine  ──▶  decision-record.json
                          ▲
        world snapshot ───┤   pinned, versioned public facts
        tenant context ───┘   customer landing zone, quota, policy
```

## Why

The Azure Next thesis argues the platform should decide placement so customers
never have to. It cannot yet, so customers do it by hand — region availability
pages, quota spreadsheets, compliance matrices, tribal knowledge. This engine is
that decision layer, built against today's Azure.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design and
[`../azure_next/VISION.md`](../azure_next/VISION.md) for the thesis.

Grounded in Microsoft's own guidance: [CAF's region-selection
criteria](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-setup-guide/regions)
supply the filters and weights, and [WAF
flows](https://learn.microsoft.com/en-us/azure/well-architected/reliability/identify-flows)
supply the structure of the input.

## Status

Early. Contracts, scenarios, and the first ingester are in; the solver is not.

- [x] Requirements contract, structured around WAF flows (`src/placement/contracts/requirements.py`)
- [x] Decision-record contract (`src/placement/contracts/decision.py`)
- [x] Four acceptance scenarios (`scenarios/`)
- [x] Snapshot model + store, with digest pinning (`src/placement/snapshot/`)
- [x] Ingester 1 — region metadata from the ARM `locations` API
- [x] Ingester 2 — service availability by region, from ARM provider metadata
- [ ] Ingester 3 — capability-level availability
- [ ] Ingester 4 — retail pricing
- [ ] Tenant context collectors (offline / live)
- [ ] Constraint solver, topology composition, scoring

## Use

Validate a requirements file and see how the engine reads it:

```bash
ape validate scenarios/eu-residency.yaml
```

Build a pinned world snapshot. Region metadata is public, but the ARM `locations`
API is subscription-scoped, so either point the engine at a subscription:

```bash
ape snapshot build --subscription <subscription-id>
```

...or collect the payload yourself and feed it in, keeping credentials out of
this process entirely:

```bash
SUB=<subscription-id>
az rest --method get --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" > locations.json
az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers?api-version=2021-04-01" > providers.json
```

```bash
ape snapshot build --locations locations.json --providers providers.json
```

Slices are additive, so a snapshot can be built up over several runs — but
regions must land before services, since provider metadata is joined against the
region table.

Then inspect it:

```bash
ape snapshot show --geo Europe
```

Snapshots are written to `snapshots/<version>/` **and committed** — they are the
reproducibility guarantee, not a cache. Each is stored with its content digest,
and loading verifies it, so a snapshot that has been edited since it was written
fails loudly instead of silently making old decision records unreproducible.

## Layout

| Path | What |
|---|---|
| `src/placement/contracts/` | Input and output schemas — the stable surface |
| `src/placement/snapshot/` | World snapshot model, store, and ingesters |
| `src/placement/tenant/` | Customer landing-zone context collectors |
| `src/placement/engine/` | Resolve, constrain, compose, score |
| `src/placement/emit/` | Reports, Azure Policy, IaC parameters |
| `scenarios/` | Acceptance fixtures — the four constraint families |
| `docs/` | Architecture and decision records |

## Develop

```bash
python -m venv .venv
.venv/Scripts/python.exe -m pip install -e ".[dev]"
.venv/Scripts/python.exe -m pytest
```

## Principles

- **Deterministic core.** Filtering and scoring are reproducible. LLMs sit at
  intake, curation, and narration — never in the ranking.
- **Pin everything.** Every decision cites the snapshot version it was made
  against, so it can be re-run and diffed.
- **Never imply certainty you don't have.** Capacity has no authoritative API;
  it is scored with explicit confidence, never asserted.
- **Record the losers.** "Why not region X" is most of the value.
