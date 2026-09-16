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

## Two gates, not one

Quota and access fail independently and have different remedies. A quota group
grants neither regional nor zonal access, so allocating quota for a family the
subscription cannot deploy buys a guaranteed failure.

**APE checks access; it does not manage it.** Closing an access gap is a support
request with lead time, which no module can do. What the module does is refuse
to allocate against a gap and say what would lift it — `NotAvailableForSubscription`
is requestable, `QuotaId` means the offer excludes the SKU and no ticket will
change it.

### The trap in `Microsoft.Compute/skus`

`locationInfo[].zones` reads like "zones you can deploy into". It is not.
`restrictions[]` removes zones, and **the restricted set is not constrained to
be a subset of the published set**:

```
Standard_D1, East US:
  zones             = ["2", "3"]      <- published
  restricted_zones  = ["1", "2", "3"] <- restricted
  effective         = []              <- nothing deployable
```

Pass both lists raw; the module does the subtraction, because the subtraction is
where the failure mode lives. On one live subscription, 60 of 1420 VM SKUs
publish zones that no restriction leaves usable.

### Placement type changes eligibility

`request.placement.type` is not a preference — it decides which families are
eligible at all:

| type | needs |
|---|---|
| `regional` | no `Location` restriction |
| `zonal` | every zone in `zones` usable for at least one size |
| `zone_redundant` | at least `zone_count` distinct usable zones for one size |

On a live subscription, `standardDFamily` is **satisfied** regionally and
**blocked_by_access** for zone 2 — the same family, region and subscription.

> **Assumption, not documented by Microsoft:** a `Zone`-type restriction blocks
> zonal placement but leaves regional placement available. It is why the API
> distinguishes `Zone` from `Location` at all. See
> [`knowledge/zone-restrictions.yaml`](../../knowledge/zone-restrictions.yaml);
> if it proves false, the regional branch in `family_deployable` is the one line
> to change.

### Quota is not evidence a family exists

A family can report a healthy quota limit in a region where Azure offers no
sizes of it. On a live subscription, **14 of the 97 families holding quota in
East US had zero SKUs there** — NC v1, H, basicA, the Promo families. Ranking on
quota alone picks one of these and produces a placement with nothing to deploy.

So `sku_access` must be **complete for the region or empty**. When supplied it is
authoritative: `Microsoft.Compute/skus` lists every SKU Azure has in the region
including restricted ones, so absence means the family is not offered. That
lands in `access.not_offered`, distinct from `access.denied`, because no support
ticket will change it.

Leave `sku_access` empty to skip the check. The decision then reports
`access.verified = false` rather than implying it passed.

### Some regions have no zones

West Central US reports 916 VM SKUs and not one availability zone. A zonal
request there is refused with `access.region_zonal = false` and
`requestable = false` — there is no ticket that adds zones to a region, and
saying otherwise sends someone after something they cannot get.

## Status values

| `status` | Meaning |
|---|---|
| `satisfied` | Existing quota covers it. No writes. |
| `needs_allocation` | A pool can cover the shortfall. Allocation is self-service and will succeed. |
| `needs_increase` | A quota limit increase is required. Increases are **evaluated, not granted**, and are refused when regional capacity is short — this is not a promise. |
| `blocked_by_rule` | A business rule refused it. |
| `blocked_by_access` | No candidate family can deploy here. Quota would not help — this needs an access request, or is final if the offer excludes it. |
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
