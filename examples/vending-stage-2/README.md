# Stage 2: quota and placement

Microsoft's [subscription vending guidance][vending] describes a pipeline whose
deployment tasks cover **Identity, Governance, Networking, Budgets and
Reporting**. Quota is not among them. CAF names the gap without filling it:

> They should also review the subscription quota limits before creating the
> subscription

> the quota request can fail, so you should run a script to handle any errors

AQV is that script, written as Terraform modules.

## Where it runs

```
data collection  ->  request pipeline  ->  subscription parameter file
                                                    |
                          stage 1: avm-ptn-sub-vending (creates the subscription)
                                                    |
                                            subscription_id
                                                    |
                          stage 2: aqv-read -> aqv-decide -> aqv-apply
```

`subscription_id` is the entire handoff contract, and `avm-ptn-sub-vending`
already outputs it. The two stages otherwise share only the parameter file.

The vending module needs no changes — it has no quota inputs and no metadata
passthrough, and with this split it needs neither.

## Why two stages rather than one module

A new subscription does not exist when Terraform makes a plan. A single-stage
module would defer every read until apply. The placement decision would then
never appear in a plan. Run separately, stage 2 plans against a subscription that already
exists: the chosen family, the quota to be written, and why every other family
lost are all visible **before** anything is written.

This also matches the guidance, which recommends a dedicated state file for each
application landing zone subscription. It avoids the provider registration race
as well. Registration completes during stage 1.

## Running it

```bash
terraform init
terraform apply \
  -var subscription_id="$(terraform -chdir=../stage-1 output -raw subscription_id)"
```

Writes are **off by default** so the decision can be reviewed first. Add
`-var apply_writes=true` to let it write quota.

## The subscription request

[`request.example.yaml`](request.example.yaml) is a subscription parameter file in
the guidance's sense — one per request, produced by the request pipeline. Fields
above `compute:` belong to stage 1 and AQV ignores them; `compute:` is what AQV
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

Business rules stay in the module call, not the subscription request — they belong to the
platform team, not the requester.

## What a decision looks like

Running the sample request against a PayAsYouGo subscription with a regional cap
of 10 vCPUs:

```
status : infeasible
reason : no candidate family can reach 64 vCPUs
class  : memory_optimized
considered: 21 families, 11 refused by the capacity growth restrictions
```

That is the correct answer. It arrives during vending, with the reasoning
attached, instead of as a failed deployment later.

[vending]: https://learn.microsoft.com/en-us/azure/architecture/landing-zones/subscription-vending
