# Stage 2: quota and placement

Microsoft's [subscription vending guidance][vending] describes a pipeline whose
deployment tasks cover **Identity, Governance, Networking, Budgets and
Reporting**. Quota is not among them. CAF names the gap without filling it:

> They should also review the subscription quota limits before creating the
> subscription

> the quota request can fail, so you should run a script to handle any errors

APE is that script, as Terraform modules rather than a script.

## Where it runs

```
data collection  ->  request pipeline  ->  subscription parameter file
                                                    |
                          stage 1: avm-ptn-sub-vending (creates the subscription)
                                                    |
                                            subscription_id
                                                    |
                          stage 2: ape-read -> ape-placement -> ape-apply
```

`subscription_id` is the entire handoff contract, and `avm-ptn-sub-vending`
already outputs it. The two stages otherwise share only the parameter file.

The vending module needs no changes — it has no quota inputs and no metadata
passthrough, and with this split it needs neither.

## Why two stages rather than one module

A brand-new subscription does not exist at plan time, so a single-stage module
would defer every read to apply and the placement decision would never appear in
a plan. Run separately, stage 2 plans against a subscription that already
exists: the chosen family, the quota to be written, and why every other family
lost are all visible **before** anything is written.

It also matches the guidance's own advice to use a dedicated state file per
application landing zone subscription, and it sidesteps the provider
registration race — by the time stage 2 runs, `Microsoft.Compute` registration
has settled.

## Running it

```bash
terraform init
terraform apply \
  -var subscription_id="$(terraform -chdir=../stage-1 output -raw subscription_id)"
```

Writes are **off by default** so the decision can be reviewed first. Add
`-var apply_writes=true` to let it write quota.

## The intake

[`intake.example.yaml`](intake.example.yaml) is a subscription parameter file in
the guidance's sense — one per request, produced by the request pipeline. Fields
above `compute:` belong to stage 1 and APE ignores them; `compute:` is what APE
adds.

The application team states a **workload class**, not an Azure VM family:

```yaml
compute:
  region: eastus
  vcpus: 64
  class: memory_optimized
  placement:
    type: zone_redundant
    zone_count: 3
```

Business rules stay in the module call, not the intake — they belong to the
platform team, not the requester.

## What a decision looks like

Running the sample intake against a PayAsYouGo subscription with a regional cap
of 10 vCPUs:

```
status : infeasible
reason : no candidate family can reach 64 vCPUs
class  : memory_optimized
considered: 21 families, 11 refused by the capacity growth restrictions
```

Which is correct, and is the point: the answer arrives at vending time with the
reasoning attached, rather than as a failed deployment weeks later.

[vending]: https://learn.microsoft.com/en-us/azure/architecture/landing-zones/subscription-vending
