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

## Status

Early. Contracts and acceptance scenarios are in place; the engine is not built yet.

- [x] Requirements contract, structured around WAF flows (`src/placement/contracts/requirements.py`)
- [x] Decision-record contract (`src/placement/contracts/decision.py`)
- [x] Four acceptance scenarios (`scenarios/`)
- [ ] World snapshot model + ingesters (region metadata first)
- [ ] Tenant context collectors (offline / live)
- [ ] Constraint solver
- [ ] Scoring + topology composition
- [ ] CLI

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
