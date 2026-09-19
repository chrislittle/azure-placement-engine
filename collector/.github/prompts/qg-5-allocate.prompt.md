---
agent: 'Quota Group Collector'
description: 'Step 5: allocate quota from the group to the target. WRITES TO AZURE.'
---

# Step 5 - allocate

**WRITES TO AZURE.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 5 - ALLOCATE QUOTA TO THE TARGET

  Writes to Azure   YES
  What changes      RAISES the target subscription's vCPU limit for one family,
                    in one region. Then repeats the identical request once
  Reversible        Yes, by step 8
  Roles used        GroupQuota Request Operator on the management group
                    Quota Request Operator on the target subscription
  API calls         PATCH quotaAllocations/{location}                 (2 writes)
                    GET   the operation, polled to a terminal state
                    GET   Microsoft.Compute usages, polled for up to 10 minutes
  Blast radius      One subscription, one VM family, one region
  Cost              None. Quota is permission to allocate, not capacity

  To run this step, reply exactly:  APPROVE STEP 5
```

---

This is the operation subscription vending depends on. Say that.

Put the real target subscription, family and new limit into the approval block.

Explain the second identical request before asking for approval: it is how the
run tells an ABSOLUTE limit from a DELTA. If the limit doubles, `limit` is a
delta and aqv-apply is the wrong shape. Pass `-SkipIdempotencyCheck` only if the
first allocation behaved badly enough that repeating it would make the tenant
harder to put back.

```powershell
./scripts/Step05-Allocate.ps1
```

This step can take ten minutes. Most of it is waiting for Microsoft.Compute to
agree with the group API. Say so before starting, so the wait does not look like
a hang.

## What to do with the result

Three numbers matter:

1. **Total time** for the allocation. A per-subscription quota write took 3m37s
   to succeed and about 35 seconds to fail, so a short timeout fails the good
   case first.
2. **The Microsoft.Compute lag.** AQV reads that API, not the group API. If it
   lags, a pipeline that allocates and then reads decides on stale numbers.
3. **Absolute or delta.** The script says which, from the repeat.

Fill in D1 to D6. If the repeat showed a delta, say so prominently: it changes
the design of the apply module.

Next: `/qg-6-failures`.
