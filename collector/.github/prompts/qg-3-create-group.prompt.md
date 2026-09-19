---
agent: 'Quota Group Collector'
description: 'Step 3: create the quota group and turn enforcement on. WRITES TO AZURE.'
---

# Step 3 - create group

**WRITES TO AZURE.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 3 - CREATE THE QUOTA GROUP

  Writes to Azure   YES - first write of the run
  What changes      Creates Microsoft.Quota/groupQuotas/{group} under {mg}
                    Adds both subscriptions to it
                    Sets enforcement on, if -Enforce is used
  Reversible        Yes, by step 8, which deletes it
  Roles used        GroupQuota Request Operator on the management group
                    Management Group Contributor on the management group
  API calls         PUT  groupQuotas/{group}                          (1 write)
                    PUT  groupQuotas/{group}/subscriptions/{sub}      (2 writes)
                    PATCH locationSettings/{location}                 (up to 2 writes)
                    GET  to read each one back
  Blast radius      One new resource under the management group. No subscription
                    quota changes in this step
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 3
```

---

Before printing the approval block, read `output/run-config.json` and put the
**real** management group ID and group name into it. The user approves the
actual resource, not a placeholder.

```powershell
./scripts/Step03-CreateGroup.ps1 -Enforce
```

Leave `-Enforce` off if the user would rather see an unenforced group first.
Section A stays unanswered without it.

## This script is untested

Say so before running it. The AQV maintainers cannot create a quota group, so
the write bodies are built from the shapes the read APIs return and from
Microsoft's documentation. At least one call may be wrong.

**A failed call is a good result.** Record the status and the error verbatim and
report it. Do not edit the script to make a call succeed: an accurate error is
worth more than a successful call nobody can reproduce.

The enforcement write in particular tries two body shapes, because nothing
documents the right one. Report which was accepted, or that neither was.

## What to do with the result

Fill in A1, A2, A3, A5, C1 and C4. If enforcement was set, say whether
`locationUsages` started working, because that is what confirms the gate.

Next: `/qg-4-fill-group`.
