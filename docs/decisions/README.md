# Decision records

Short, dated records of architectural decisions and the reasoning behind them.
One file per decision, `NNNN-slug.md`, append-only — supersede rather than edit.

- [0001 — Terraform is the reference implementation](0001-terraform-is-the-reference-implementation.md)

Decisions taken before the pivot to IaC modules described an advisory engine
that ranked Azure regions and recommended placements for a human to act on.
They are **superseded** — this project decides and writes.

That implementation is not published. It is kept on the author's machine at the
`v0-advisory-engine` tag, so a reference to it here is history, not something
you can check out.
