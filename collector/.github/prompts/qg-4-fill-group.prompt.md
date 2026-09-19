---
agent: 'Quota Group Collector'
description: 'Step 4: move quota out of the donor into the group. WRITES TO AZURE.'
---

# Step 4 - fill group

**WRITES TO AZURE.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 4 - MOVE QUOTA INTO THE GROUP

  Writes to Azure   YES
  What changes      LOWERS the donor subscription's vCPU limit for one family,
                    in one region, by the number of cores in run-config.json
  Reversible        Yes, by step 8, which allocates it back to the baseline
  Roles used        GroupQuota Request Operator on the management group
                    Quota Request Operator on the donor subscription
  API calls         PATCH quotaAllocations/{location}                 (1 write)
                    GET   the operation, polled to a terminal state
                    GET   groupQuotaLimits, quotaAllocations, usages
  Blast radius      One subscription, one VM family, one region. The donor can
                    no longer create virtual machines above the lowered limit
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 4
```

---

Put the real donor subscription, family, region and core count into the
approval block before printing it, from `output/run-config.json`.

Say this plainly, in the approval block or just above it:

> Quota is not capacity. Lowering the donor's limit does not stop a running
> virtual machine. It stops that subscription creating new ones above the
> lowered limit.

```powershell
./scripts/Step04-FillGroup.ps1
```

Add `-BelowUsed` **only** if the user asks for it. It deliberately tries to move
the donor's limit below what it is using, which answers E2 and is the one case
in this collector that could inconvenience a running workload. The script skips
it when the donor is using nothing.

## This script is untested

Same as step 3. A refusal is a result. Record it verbatim and stop rather than
working around it.

## What to do with the result

The thing to watch is whether `groupQuotaLimits` stopped being empty. If it did,
the group now holds quota and step 2 can be re-run to answer all of section B
properly. Offer that.

Fill in E1, E2, E3, B3 and B4.

Next: `/qg-5-allocate`.
