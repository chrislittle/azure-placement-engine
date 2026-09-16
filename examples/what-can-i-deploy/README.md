# What can I deploy?

For the **application team**, not the platform team.

Ask a subscription what it can run right now: which VM family to use, how many
vCPUs it can take, and what is refused.

Two ways to ask. They give the same answer.

```bash
# Terraform
terraform init
terraform apply \
  -var subscription_id=$SUB \
  -var region=eastus \
  -var vcpus=64 \
  -var category=MemoryOptimized
```

```powershell
# PowerShell, for the Bicep path or for anyone who would rather not run Terraform
./Get-WhatCanIDeploy.ps1 -SubscriptionId $sub -Region eastus -VCpus 64 `
    -Category MemoryOptimized
```

There is no Bicep version. Bicep only writes, and this asks a question.

## It does not apply the platform's rules

It reads the quota the subscription actually has.

It does not need the rules. The platform team's rules already decided what quota
was granted; asking again does not re-run them. Rules are enforced in the
pipeline, where the platform team controls which rules file is used. A script a
workload team runs could never enforce anything — they would simply not pass the
file.

`-RulesFile` (or `-var rules_file=` for Terraform) exists for a platform
engineer previewing a decision before running the pipeline. A workload team does
not need it.

## It writes nothing

`Reader` on the subscription is enough. The read step calls only read APIs, and
the decide step does not touch Azure at all.

So an application team can run this themselves, whenever they want, without
involving the platform team and with no risk of changing anything.

## Why this rather than a value recorded at hand-over

A value written down at vending time is a snapshot. Quota changes, Azure
restricts a series, a region grant arrives. This asks the subscription as it is
now.

## A real answer

Every block below is captured output, not a sketch. The subscription is
PayAsYouGo, with a regional cap of 16 vCPUs and every VM family limited to 10.

Asked for 64 memory-optimized vCPUs:

```text
  Can I deploy 64 vCPUs in eastus?
  Not yet

  status     : infeasible
  reason     : no candidate family can reach 64 vCPUs
  rule       : none — this is the quota the subscription has

  Why not the others:
    standardDFamily                    limit=10     unused=10     short by 54 vCPUs
    standardGSFamily                   limit=10     unused=10     short by 54 vCPUs
    standardGFamily                    limit=10     unused=10     short by 54 vCPUs
    StandardFXmsv2Family               limit=10     unused=10     short by 54 vCPUs
    StandardFXmdsv2Family              limit=10     unused=10     short by 54 vCPUs
```

Asked for 8 instead:

```text
  Can I deploy 8 vCPUs in eastus?
  Yes

  status     : satisfied
  reason     : existing quota covers the request
  rule       : none — this is the quota the subscription has
  use family : StandardDadsv7Family

  Sizes you can deploy:
    Standard_D8ads_v7            8 vCPU   deploy 1
    Standard_D4ads_v7            4 vCPU   deploy 2
    Standard_D2ads_v7            2 vCPU   deploy 4

  Why not the others:
    StandardDadsv7Family               limit=10     unused=10     chosen
    standardAv2Family                  limit=10     unused=10     eligible, outranked
    StandardFadsv7Family               limit=10     unused=10     eligible, outranked
```

The same 64-vCPU question through Terraform. Same decision, as outputs:

```hcl
answer = {
  "can_i_deploy" = false
  "reason" = "no candidate family can reach 64 vCPUs"
  "rules_applied" = "none — this is what Azure permits, not what the platform would grant"
  "status" = "infeasible"
  "use_family" = null
}
blocked = {
  "growth_restricted" = tolist([])
  "no_access" = tolist([
    "standardPBSFamily",
  ])
  "not_offered" = tolist([
    "basicAFamily",
    "internalNDMSv1Family",
    "standardA0_A7Family",
    # ... 11 more
  ])
  "remediation" = "Raise a region or SKU access request (quota type: Compute-VM subscription limit increases) for the denied families."
}
what_would_need_writing = []
```

`why_not_the_others` carried 82 entries on that run, one per family considered.

At 8 vCPUs the `sizes` output carries what to deploy:

```hcl
sizes = [
  {
    "count_at" = 1
    "name" = "Standard_D8ads_v7"
    "vcpus" = 8
    "zones" = tolist([
      "1",
      "2",
      "3",
    ])
  },
  {
    "count_at" = 2
    "name" = "Standard_D4ads_v7"
    "vcpus" = 4
    "zones" = tolist([
      "1",
      "2",
      "3",
    ])
  },
  {
    "count_at" = 4
    "name" = "Standard_D2ads_v7"
    "vcpus" = 2
    "zones" = tolist([
      "1",
      "2",
      "3",
    ])
  },
]
```

`remediation` is populated whenever any family was denied, so it appears even on
an answer that succeeded. The PowerShell version prints it only when access is
what refused the request, because a rule refusal or a size refusal is not fixed
by a SKU access request.

## What comes back

| Output | Use |
|---|---|
| `answer` | Can I deploy, which family to use, and why. |
| `sizes` | What to actually deploy, largest first. `count_at` is how many of that size the request needs. |
| `what_would_need_writing` | Empty means the quota is already there. Anything here needs the platform team, because raising quota needs more than `Reader`. |
| `why_not_the_others` | Every family considered, with its numbers and why it lost. |
| `blocked` | Families that cannot be deployed here at all, and what would lift that. |

A family cannot be deployed; a size can. `answer.use_family` names the quota
bucket, and `sizes` names what goes in the template. A size larger than the
quota is never listed, because one instance of it would exceed the limit.

Put the size in your own IaC. **This example does not deploy it. Nothing in this
repository does.**

Add `-AsJson` to the PowerShell version for the whole decision as JSON, for a
pipeline to act on.
