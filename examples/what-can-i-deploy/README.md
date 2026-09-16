# What can I deploy?

For the **application team**, not the platform team.

Ask a subscription what it can run right now: which VM family to use, how many
vCPUs it can take, and what is refused.

```bash
terraform init
terraform apply \
  -var subscription_id=$SUB \
  -var region=eastus \
  -var vcpus=64 \
  -var category=MemoryOptimized
```

## It writes nothing

`Reader` on the subscription is enough. The read module calls only read APIs,
and the decide module holds no resources at all.

So an application team can run this themselves, whenever they want, without
involving the platform team and without any risk of changing anything.

## Why this rather than a record from hand-over

A value written at vending time is a snapshot. Quota changes, Azure restricts a
series, a region grant arrives. This asks the subscription as it is now.

## What comes back

| Output | Use |
|---|---|
| `answer` | Can I deploy, which family to use, and why. |
| `what_would_need_writing` | Empty means the quota is already there. Anything here needs the platform team, because raising quota needs more than Reader. |
| `why_not_the_others` | Every family considered, with its numbers and why it lost. |
| `blocked` | Families that cannot be deployed here at all, and what would lift that. |

A worked answer:

```
answer = {
  can_i_deploy = true
  status       = "satisfied"
  reason       = "existing quota covers the request"
  use_family   = "StandardEadsv7Family"
}
```

`use_family` is the family to put in your own deployment. This example does not
deploy it. Nothing in this repository does.
