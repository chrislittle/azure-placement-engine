---
agent: 'Quota Group Collector'
description: 'Step 2: read every group API. Writes nothing.'
---

# Step 2 - read group

**Writes nothing.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 2 - READ THE GROUP APIS

  Writes to Azure   NO
  What changes      Nothing. Every call is a GET
  Reversible        Nothing to reverse
  Roles used        Reader, and GroupQuota Request Operator for the group reads
  API calls         GET groupQuotas/{group}                           (1)
                    GET locationSettings/{location} and the list      (2)
                    GET groupQuotaLimits/{location}                   (1)
                    GET locationUsages/{location}                     (1)
                    GET quotaAllocations/{location}                   (1)
                    GET subscriptions, groupQuotaRequests             (2)
                    GET quotaAllocationRequests                       (1)
                    GET quotaTransfers, incomingQuotaTransfers        (2)
  Blast radius      None
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 2
```

---

Run it against an **existing** group if step 1 found one. That is the most
valuable single run in this collector, because it is the only way to see a group
that holds quota without writing anything.

```powershell
./scripts/Step02-ReadGroup.ps1 -GroupName <group> -ManagementGroupId <mg> -SubscriptionId <a member>
```

With no arguments it reads the group named in `run-config.json`, which does not
exist until step 3.

## What to look for

Four results matter more than the rest. Report each one plainly.

| Look at | Why |
|---|---|
| `groupQuotaLimits` empty or not | An empty group returns `{}` with HTTP 200. A non-empty one is the case AQV has never read. Answers B1 and B2 |
| `locationUsages` status | HTTP 405 means enforcement is off. The message names the gate. Answers part of A |
| The name comparison | Whether the group API and Microsoft.Compute agree on family names. On the maintainers' run, 231 of 232 differed by case alone. Answers B6 |
| `quotaAllocationRequests` status | It returned HTTP 500 for the maintainers on two api-versions. If it works here, the group state is what differs. Answers D4 |

Fill in B1, B2, B3, B6, C4, A2 and A5 in `output/findings.yaml` from whatever
this returned, each citing `captures/02-read-group.json`.

If the group is empty, say which questions are still open and that step 4 is
what fills it.

Next: `/qg-3-create-group`, which is the first step that writes.
