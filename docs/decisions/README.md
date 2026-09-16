# Decision records

Short, dated records of architectural decisions and the reasoning behind them.
One file per decision, `NNNN-slug.md`, append-only — supersede rather than edit.

- [0001 — Terraform is the reference implementation](0001-terraform-is-the-reference-implementation.md)

Decisions taken before the pivot to IaC modules described an advisory engine
that ranked Azure regions. They are **superseded**, and preserved at the
`v0-advisory-engine` tag rather than in the tree:

```bash
git show v0-advisory-engine:docs/ARCHITECTURE.md
```
