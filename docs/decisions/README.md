# Decision records

Short, dated records of architectural decisions and the reasoning behind them.
One file per decision, `NNNN-slug.md`, append-only — supersede rather than edit.

The seven contract decisions taken during initial scoping are captured inline in
[`../ARCHITECTURE.md`](../ARCHITECTURE.md#decisions-taken), together with their
grounding in CAF (region-selection criteria) and WAF (flows). Also recorded there:

- Advisory plane, not control plane
- Input schema as an ancestor of the thesis's `outcome.yaml`
- Deterministic solver core; LLMs only at intake, curation, and narration
- Two separate data planes (pinned world snapshot vs. live tenant context)
- Capacity split: hard elimination where proven, scored confidence where inferred
- Unknown capability is a risk on the survivor, never a silent pass
