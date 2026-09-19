---
agent: 'Quota Group Collector'
description: 'Step 6: ask for things Azure should refuse. WRITES TO AZURE, expects failure.'
---

# Step 6 - failures

**WRITES TO AZURE.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 6 - RECORD HOW AZURE REFUSES

  Writes to Azure   YES, and every write is expected to FAIL
  What changes      Nothing, if Azure refuses as expected. A case that succeeds
                    changes one subscription's limit and step 8 puts it back
  Reversible        Yes, by step 8
  Roles used        GroupQuota Request Operator on the management group
                    Quota Request Operator on the subscriptions
  API calls         PATCH quotaAllocations, once per case               (up to 5)
  Blast radius      One subscription, one family, one region per case
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 6
```

---

Ask which cases the user wants. Each optional one needs something only they can
supply, and each is skipped cleanly without it:

- `-GrowthRestrictedFamily` a family under the July 2026 capacity growth
  restrictions. This answers whether a quota group can route around a growth
  restriction, which is significant either way.
- `-ForeignSubscriptionId` a subscription in a different quota group.
- `-UnreachableRegion` a region the target has no access to. This is what
  confirms AQV is right to check access before quota.

```powershell
./scripts/Step06-Failures.ps1 -GrowthRestrictedFamily <family> -UnreachableRegion <region>
```

## Reading the result

Every case is expected to fail. **A case that SUCCEEDS is the interesting
result** and the script says so in red. Report those first.

Record each refusal in full: status code, `code`, `message` and any `details`.
The wording is what AQV matches on, so paraphrasing it destroys the value.

Fill in F1, F2, F3, C2 and D7.

Next: `/qg-7-iac`, or `/qg-8-teardown` to put everything back now.
