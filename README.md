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
- [x] Ingester 3 — capability level (region zones, Storage SKUs, Postgres per-region flags)
- [x] Ingester 4 — VM SKUs from `Microsoft.Compute/skus` (projected per region)
- [x] Tenant context — SKU restrictions **and vCPU quota** as remediation signals
- [x] `ape collect` — one-command reproducible collection
- [x] `knowledge/` — curated rules extracted from code, dated and sourced
- [x] **Solver** — resolve, constrain, derive topology, score, record
- [ ] Ingester 5 — latency matrix and retail pricing (the two unscored dimensions)
- [ ] Secondary-region selection informed by latency
- [ ] Tenant context — policy `allowedLocations`, existing footprint
- [ ] Constraint solver, topology composition, scoring

## Use

Collect every raw payload, then build a snapshot from it:

```bash
ape collect --out payloads
```

```bash
ape snapshot build --payloads payloads
```

`collect` uses whatever `az` is already logged in as. Payloads are kept as raw
API responses, so a projection bug can be fixed and replayed without
re-downloading ~250 MB. Individual failures are normal — Postgres is not offered
in every region, and that is a real answer rather than an error.

Decide where a workload should run:

```bash
ape place scenarios/eu-residency.yaml --tenant tenant-context.json -o decision.json
```

Or just check how the engine reads a requirements file:

```bash
ape validate scenarios/eu-residency.yaml
```

Inspect a snapshot:

```bash
ape snapshot show --geo Europe
```

Snapshots are written to `snapshots/<version>/` **and committed** — they are the
reproducibility guarantee, not a cache. Each is stored with its content digest,
and loading verifies it, so a snapshot that has been edited since it was written
fails loudly instead of silently making old decision records unreproducible.

Subscription-specific facts (SKU restrictions, quota, capacity-reservation
support) go to a separate tenant context, which is **never committed**:

```bash
ape snapshot build --payloads payloads --tenant-out tenant-context.json
```

## Three kinds of data

Kept apart deliberately, because they refresh differently and rot differently:

| Kind | Where | Refresh |
|---|---|---|
| **Observed facts** — regions, services, capabilities, SKUs | `snapshots/` (committed, digest-pinned) | `ape collect` |
| **Tenant facts** — restrictions, quota, reservation support | tenant context (never committed) | `ape collect` |
| **Curated knowledge** — quota adjustment tiers, which capacity signals lie | `knowledge/*.yaml` (dated, sourced) | human review |

The third kind is what no API returns: that `Microsoft.Quota` is regional-only,
that spot placement scores describe a different pool from on-demand, which
regions are Microsoft-internal. It used to live in docstrings, where it could not
be reviewed or dated and would rot invisibly. Each file now carries a `reviewed:`
date, and `ape snapshot build` warns when one is past its review window.

## Layout

| Path | What |
|---|---|
| `src/placement/contracts/` | Input and output schemas — the stable surface |
| `src/placement/snapshot/` | World snapshot model, store, and ingesters |
| `src/placement/tenant/` | What this subscription can reach — never committed |
| `src/placement/engine/` | Resolve, constrain, compose, score |
| `src/placement/emit/` | Reports, Azure Policy, IaC parameters |
| `scenarios/` | Acceptance fixtures — the four constraint families |
| `knowledge/` | Curated rules no API returns — dated and sourced |
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
- **Distinguish "unavailable" from "not yet requested."** Azure region and
  zonal access are not open by default; much of what looks unavailable is a
  support request away. Eliminations carry the remediation that would lift them.
