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

- The **management group** their quota group sits under. Step 1's own listing
  shows which groups exist and where, so ask after showing them, not before.
- The **VM family** to move, exactly as step 0 printed it. Family names are
  case sensitive.
- How many **cores** to move. 8 is plenty. More is not a better experiment.
- **Which quota group** to use, by name, from the ones step 1 lists. The
  collector joins an existing group; it does not create one.

Then run:

```powershell
./scripts/Step01-Discover.ps1 -DonorSubscriptionId <donor> -TargetSubscriptionId <target> `
    -Region <region> -ManagementGroupId <mg> -Family <family> -Cores 8
```

## What to do with the result

**Name every quota group that turned up and ask which to use.** A group that
already holds quota is the best evidence in this whole collector, and step 2
reads it with no writes at all. Offer that route first.

**If none turned up**, stop. The collector joins an existing group. Say that
`scripts/New-SandboxGroup.ps1` can stand one up in a sandbox tenant, and that it
is deliberately outside the numbered run.

**If either subscription is already in a group**, stop and say so. A
subscription can be in only one group.

This step writes `output/run-config.json`. Every later step reads it, so no
later step takes a subscription ID on the command line. Say that: it is why a
typo cannot send a write to the wrong subscription.

Next: `/qg-2-read-group`.
