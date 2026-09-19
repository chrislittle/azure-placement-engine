---
agent: 'Quota Group Collector'
description: 'Step 3: add the two subscriptions to the group they already have. WRITES TO AZURE.'
---

# Step 3 - join the group

**WRITES TO AZURE.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 3 - JOIN THE QUOTA GROUP

  Writes to Azure   YES - first write of the run
  What changes      Adds the donor and target subscriptions to the EXISTING
                    quota group. Creates nothing
                    With -Enforce, also turns enforcement on for the region
  Reversible        Yes, by step 8, which removes only what this step added
  Roles used        GroupQuota Request Operator on the management group
  API calls         PUT  groupQuotas/{group}/subscriptions/{sub}    (up to 2 writes)
                    PUT  locationSettings/{location}                (1 write, with -Enforce)
                    GET  to read each one back, and to poll
  Blast radius      Two subscriptions join a group. A subscription can belong to
                    only ONE group, so this is not a no-op for them
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 3
```

---

**This step does not create anything.** The collector is built for a tenant that
already has a quota group. Read `output/run-config.json` and put the **real**
group name and management group into the approval block, so the user approves
the actual group rather than a placeholder.

If the group named there does not exist, the script stops and says so. Do not
offer to create one. `scripts/New-SandboxGroup.ps1` exists for a sandbox tenant
with no group at all, and it is not part of this run.

```powershell
./scripts/Step03-JoinGroup.ps1 -Enforce
```

Ask before passing `-Enforce`. It changes a setting on a group the user may
depend on for real work. Without it, section A stays unanswered and
`locationUsages` keeps refusing.

## Membership matters more than it looks

A subscription can belong to **one** quota group at a time. Joining this one
takes it out of any other. Say that plainly before the approval, and check
step 1's output: it records whether either subscription was already a member of
something.

## This script is untested

Say so before running it. The AQV maintainers cannot exercise membership on an
eligible billing account, so the calls are built from the shapes the read APIs
return.

**A failed call is a good result.** Record the status and the error verbatim.
Do not edit the script to make a call succeed: an accurate error is worth more
than a successful call nobody can reproduce.

C3 in particular is answered by a refusal. If an ineligible account or a
subscription already in another group is rejected here, that error is how AQV
would detect the condition cleanly instead of failing later.

## What to do with the result

Fill in C1, C2, C3 and C4. With `-Enforce`, also A1, A2 and A3 — and say
whether `locationUsages` started working, because that is what confirms the
gate.

Next: `/qg-4-fill-group`.
