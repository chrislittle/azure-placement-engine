---
agent: 'Quota Group Collector'
description: 'Step 8: put the quota back and leave the group as it was found. WRITES TO AZURE.'
---

# Step 8 - teardown

**WRITES TO AZURE.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 8 - PUT IT BACK

  Writes to Azure   YES
  What changes      Every family that differs from the step 0 baseline is
                    allocated back to its baseline limit
                    The subscriptions step 3 added are removed from the group
  Does NOT change   Your quota group. It is not this collector's to delete
                    Any subscription that was in the group before this run
  Reversible        This IS the reversal
  Roles used        GroupQuota Request Operator on the management group
                    Quota Request Operator on both subscriptions
  API calls         PATCH quotaAllocations, once per drifted family
                    DELETE groupQuotas/{group}/subscriptions/{sub}   (up to 2)
  Blast radius      Only families this run changed, and only members it added
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 8
```

---

Run `-WhatIf` first, always, and show the user what it would do:

```powershell
./scripts/Step08-Teardown.ps1 -WhatIf
```

Then, after they have seen it and approved:

```powershell
./scripts/Step08-Teardown.ps1
```

`-KeepMembership` puts the quota back but leaves the subscriptions in the group,
which is what to use between runs.

## It does not delete the group

The collector joins a group the user already had, so deleting it would be
destroying something it did not create. `-DeleteSandboxGroup` exists only for a
group made with `New-SandboxGroup.ps1`, and the script refuses unless
`run-config.json` records this collector creating it. Do not offer that flag
unless the user made a sandbox group.

## Safety properties worth stating

- It works from the step 0 baseline, so it does not care which of steps 3 to 6
  ran, or whether one failed halfway.
- It removes only the subscriptions step 3 added, recorded in
  `run-config.json` at the time.
- It is safe to run more than once.

## Afterwards

Always run:

```powershell
./scripts/Compare-Baseline.ps1
```

Report the result. If anything is still drifted, say so plainly rather than
burying it in a summary. Some drift is not this collector's doing: Azure raises
the regional cap on its own when a family limit goes up.

Next: `/qg-9-package`.
