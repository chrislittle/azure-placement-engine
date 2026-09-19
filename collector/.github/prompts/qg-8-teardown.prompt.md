---
agent: 'Quota Group Collector'
description: 'Step 8: put the quota back and remove the group. WRITES TO AZURE.'
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
                    Both subscriptions are removed from the group
                    The group this collector created is deleted
  Reversible        This IS the reversal
  Roles used        GroupQuota Request Operator on the management group
                    Quota Request Operator on both subscriptions
  API calls         PATCH quotaAllocations, once per drifted family
                    DELETE groupQuotas/{group}/subscriptions/{sub}     (2)
                    DELETE groupQuotas/{group}                         (1)
  Blast radius      Only families that this run changed. A group that existed
                    before this run is never deleted
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

`-KeepGroup` puts the quota back but leaves the group, which is what to use
between runs.

## Safety properties worth stating

- It works from the step 0 baseline, so it does not care which of steps 3 to 6
  actually ran, or whether one failed halfway.
- It only deletes a group named `aqvcollector`. A group that was already in the
  tenant is left alone whatever else happened.
- It is safe to run more than once.

## Afterwards

Always run:

```powershell
./scripts/Compare-Baseline.ps1
```

Report the result. If anything is still drifted, say so plainly and do not try
to hide it in a summary. Some drift is not this collector's doing: Azure raises
the regional cap on its own when a family limit goes up.

Next: `/qg-9-package`.
