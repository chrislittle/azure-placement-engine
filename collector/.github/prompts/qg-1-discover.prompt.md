---
agent: 'Quota Group Collector'
description: 'Step 1: find management groups and existing quota groups. Writes nothing.'
---

# Step 1 - discover

**Writes nothing.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 1 - DISCOVER

  Writes to Azure   NO
  What changes      Nothing in Azure. Writes output/run-config.json locally
  Reversible        Nothing to reverse
  Roles used        Reader on the management groups
                    Reader on both subscriptions
  API calls         GET managementGroups                              (1)
                    GET groupQuotas, per management group             (n)
                    GET groupQuotas/{group}/subscriptions             (n)
                    GET Microsoft.Compute/locations/{region}/usages   (1)
  Blast radius      None
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 1
```

---

Ask for:

- The **management group** the quota group will be created under. Any one the
  user can write to. Quota groups are orthogonal to the management group
  hierarchy, so this is an access-control choice and nothing else.
- The **VM family** to move, exactly as step 0 printed it. Family names are
  case sensitive.
- How many **cores** to move. 8 is plenty. More is not a better experiment.
- Optionally a **group name**. Lower-case letters and digits only, starting with
  a letter. A hyphen is rejected by the schema. The default is `aqvcollector`.

Then run:

```powershell
./scripts/Step01-Discover.ps1 -DonorSubscriptionId <donor> -TargetSubscriptionId <target> `
    -Region <region> -ManagementGroupId <mg> -Family <family> -Cores 8
```

## What to do with the result

**If an existing quota group turned up, say so clearly.** A group that already
holds quota is much better evidence than the empty one step 3 would create, and
it can be read in step 2 with no writes at all. Offer that route first.

**If either subscription is already in a group**, stop and say so. A
subscription can be in only one group.

This step writes `output/run-config.json`. Every later step reads it, so no
later step takes a subscription ID on the command line. Say that: it is why a
typo cannot send a write to the wrong subscription.

Next: `/qg-2-read-group`.
