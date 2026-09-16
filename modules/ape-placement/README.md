# `ape-placement`

Decides which VM family a vended subscription should get, and what its quota
limit should be set to. **Holds no resources** — it reads a request, pool state
its caller fetched, and the platform team's rules, and returns a decision plus
the writes that would realise it. Applying them is a separate concern.

That split is what makes it testable: `terraform test` runs the whole decision
surface against fixtures, with no subscription and no credentials.

```bash
terraform test
```

## The regional cap

The one thing to understand before reading the logic. `regional_cores_limit` is
a region-wide vCPU cap that sits under every family, and it is **not** the sum
of the family limits — it is usually far smaller. A live PAYG subscription reads:

```
cores  limit=10          <- the real constraint
97 families, each reporting limit=10..12
```

Ranking on family headroom alone would find hundreds of vCPUs that cannot be
deployed. Every decision is bounded by the regional cap, and when the cap binds,
`writes_required` raises it first — a family limit above the regional cap is
unusable.

## Status values

| `status` | Meaning |
|---|---|
| `satisfied` | Existing quota covers it. No writes. |
| `needs_allocation` | A pool can cover the shortfall. Allocation is self-service and will succeed. |
| `needs_increase` | A quota limit increase is required. Increases are **evaluated, not granted**, and are refused when regional capacity is short — this is not a promise. |
| `blocked_by_rule` | A business rule refused it. |
| `infeasible` | No candidate family can reach the requested size. |

The `needs_allocation` / `needs_increase` split is the whole point. A null
`available` on a family means there is no pool behind the subscription, and the
module treats that as **unproven rather than unlimited** — it will not imply a
guarantee that Azure has not given.

## Rules

Evaluated in order; the first whose `environments` matches wins. A rule with no
`environments` matches everything, so put the catch-all last.

```hcl
rules = [
  {
    name            = "dev stays off GPU and stays small"
    environments    = ["dev"]
    family_denylist = ["standardNCFamily"]
    max_vcpus       = 16
  },
  {
    name             = "prod uses approved families, cheapest first"
    environments     = ["prod"]
    family_allowlist = ["standardDSv5Family", "standardDSv3Family"]
    prefer           = "listed_order"
  },
]
```

`prefer` is `most_headroom` (default), `least_headroom`, or `listed_order` —
the order the rule's own allowlist names them, which is how a platform team says
"use up the cheap family first".

## Losers are recorded

`decision.considered` carries every candidate with its numbers and why it lost.
A placement that cannot say why it rejected the alternatives is not auditable,
and "why not that family" is most of what anyone actually asks.

## Live example

[`examples/live-subscription`](../../examples/live-subscription) runs it against
real subscription state read by [`scripts/read_pool.py`](../../scripts/read_pool.py).
