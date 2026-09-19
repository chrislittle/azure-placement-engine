---
agent: 'Quota Group Collector'
description: 'Step 0: check eligibility and record the baseline. Writes nothing.'
---

# Step 0 - preflight

**Writes nothing.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 0 - PREFLIGHT AND BASELINE

  Writes to Azure   NO
  What changes      Nothing. Every call is a GET
  Reversible        Nothing to reverse
  Roles used        Reader on both subscriptions
                    Billing account reader, for the agreement type
  API calls         GET Microsoft.Billing/billingAccounts             (1)
                    GET roleDefinitions, filtered                     (2)
                    GET provider registration, per subscription       (4)
                    GET Microsoft.Compute/locations/{region}/usages   (2)
  Blast radius      None
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 0
```

---

Ask for three things first, and do not guess any of them:

- The **donor** subscription ID. Quota will be moved OUT of it. It needs spare
  vCPU quota and should not be production.
- The **target** subscription ID. Quota will be allocated TO it.
- One Azure **region**. Everything in the run happens there.

They must be different subscriptions.

Then run:

```powershell
./scripts/Step00-Preflight.ps1 -DonorSubscriptionId <donor> -TargetSubscriptionId <target> -Region <region>
```

## What to do with the result

Report the agreement type, whether `GroupQuota Request Operator` was found, the
provider registration states, and how many donor families have room.

Fill in these in `output/findings.yaml`:

- `run.billing_account_type`
- `run.az_cli_version`

**If no eligible agreement type was found**, stop. Tell the user quota groups
need EA, MCA-Enterprise or Internal, and that the capture is still worth
sending: what an ineligible account returns is a finding AQV needs.

**If the agreement type is MicrosoftCustomerAgreement**, say that MCA-Online and
MCA-Enterprise look the same here and ask the user which theirs is. Do not
assume.

The baseline this step records is what makes every later write reversible. Say
so, and say that `./scripts/Compare-Baseline.ps1` will check it at any point.

Next: `/qg-1-discover`.
