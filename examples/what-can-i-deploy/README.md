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

Both of these are actual output from a PayAsYouGo subscription with a regional
cap of 10 vCPUs, asked for 64.

```text
  Can I deploy 64 vCPUs in eastus?
  Not yet

  status     : infeasible
  reason     : no candidate family can reach 64 vCPUs

  To lift it : Raise a region or SKU access request (quota type: Compute-VM
               subscription limit increases) for the denied families.

  Why not the others:
    standardDFamily                    limit=10     unused=10     short by 54 vCPUs
    standardGSFamily                   limit=10     unused=10     short by 54 vCPUs
    StandardEadsv7Family               limit=10     unused=10     short by 54 vCPUs
    standardESv3Family                 limit=10     unused=10     short by 54 vCPUs
```

The same question through Terraform:

```hcl
answer = {
  "can_i_deploy" = false
  "reason"       = "no candidate family can reach 64 vCPUs"
  "status"       = "infeasible"
  "use_family"   = null
}
blocked = {
  "growth_restricted" = []
  "no_access"         = ["standardPBSFamily"]
  "not_offered"       = []
  "remediation"       = "Raise a region or SKU access request (quota type: Compute-VM subscription limit increases) for the denied families."
}
what_would_need_writing = []
why_not_the_others = [
  {
    "family"      = "StandardEadsv7Family"
    "limit"       = 10
    "used"        = 0
    "unused"      = 10
    "allocatable" = 0
    "outcome"     = "short by 54 vCPUs"
  },
  # ... one entry for every family considered
]
```

Asked for 8 vCPUs instead, the same subscription answers:

```text
  Can I deploy 8 vCPUs in eastus?
  Yes

  status     : satisfied
  reason     : existing quota covers the request
  use family : StandardEadsv7Family

  Why not the others:
    StandardEadsv7Family               limit=10     unused=10     chosen
    standardDFamily                    limit=10     unused=10     eligible, outranked
    StandardEpsv6Family                limit=10     unused=10     eligible, outranked
```

## What comes back

| Output | Use |
|---|---|
| `answer` | Can I deploy, which family to use, and why. |
| `what_would_need_writing` | Empty means the quota is already there. Anything here needs the platform team, because raising quota needs more than `Reader`. |
| `why_not_the_others` | Every family considered, with its numbers and why it lost. |
| `blocked` | Families that cannot be deployed here at all, and what would lift that. |

A family cannot be deployed. `answer.use_family` names the quota bucket; the
`sizes` output names what to actually deploy:

```text
  Sizes you can deploy:
    Standard_D8ads_v7            8 vCPU   deploy 1
    Standard_D4ads_v7            4 vCPU   deploy 2
    Standard_D2ads_v7            2 vCPU   deploy 4
```

`deploy` is how many of that size the requested vCPUs need. Put the size in your
own IaC. **This example does not deploy it. Nothing in this repository does.**

Add `-AsJson` to the PowerShell version for the whole decision as JSON, for a
pipeline to act on.
