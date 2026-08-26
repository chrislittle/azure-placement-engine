# Decision records

Short, dated records of architectural decisions and the reasoning behind them.
One file per decision, `NNNN-slug.md`, append-only — supersede rather than edit.

The decisions already taken are captured inline in
[`../ARCHITECTURE.md`](../ARCHITECTURE.md) while the design is still moving:

- Advisory plane, not control plane
- Input schema as an ancestor of the thesis's `outcome.yaml`
- Deterministic solver core; LLMs only at intake, curation, and narration
- Two separate data planes (pinned world snapshot vs. live tenant context)
- Capacity as scored confidence, never a boolean
- Output is a topology, not a region
