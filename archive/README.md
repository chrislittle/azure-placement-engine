# Archive

Superseded work, kept for reference. **Nothing here describes the current
design.** Do not extend it, and do not treat its documents as statements of
intent.

## `v0-advisory-engine/`

Tagged `v0-advisory-engine`. A Python engine that took a requirements file,
ranked every Azure region against CAF criteria, and emitted an evidenced
decision record naming the winners and the losers.

It was explicitly an **advisory plane, not a control plane** — it recommended,
a human acted. The current direction inverts that: APE writes, as IaC modules,
attached to subscription vending.

Archived in full rather than deleted because the ingesters and the tenant-context
work encode real findings about Azure's APIs that would be expensive to rediscover.

### What carried forward

- `knowledge/` — curated facts no API returns. Still live, still at the repo
  root. `capacity-signals.yaml` and `quota-adjustment.yaml` are directly
  load-bearing for the new shape.
- The separation of **decide** from **apply**. `engine/` never touched Azure;
  `emit/` did. The same seam is why the new decision module holds no resources.
- The two-gate model: entitlement and quota are separate, with separate remedies.

### What is deliberately dead

- Global region ranking and weighted multi-dimensional scoring. Placement now
  happens *within* what the platform already owns, which is a filter-and-rank
  over a small pool, not a solve.
- The four acceptance scenarios, which framed region selection as the problem.
- The latency and pricing ingesters, never built.
- `snapshots/` — pinned world state. The new centre of gravity is live platform
  state, not a committed snapshot.
