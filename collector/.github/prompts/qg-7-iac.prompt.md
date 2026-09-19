---
agent: 'Quota Group Collector'
description: 'Step 7: check what Terraform's azapi provider can express. Writes nothing.'
---

# Step 7 - iac

**Writes nothing.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 7 - TERRAFORM REACHABILITY

  Writes to Azure   NO - terraform plan only, never apply
  What changes      Nothing in Azure. Writes files under output/terraform
  Reversible        Nothing to reverse
  Roles used        Reader, so the provider can authenticate
  API calls         None directly. The provider resolves its own schema
  Blast radius      None
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 7
```

---

```powershell
./scripts/Step07-Iac.ps1
```

Skipped automatically if Terraform is not on PATH. That is fine, and the rest of
the package still matters.

## What the maintainers already found

Said plainly so the partner's run can be compared rather than repeated:

- `Microsoft.Quota/groupQuotas/quotaAllocations@2025-09-01` is **not in azapi's
  embedded schema**. `terraform plan` fails with "resource type ... can't be
  found" until `schema_validation_enabled = false` is set on the resource.
- With validation off, azapi **does** accept a full body, and the plan resolves.
- A quota group name must match `^[a-z][a-z0-9]*$`. A hyphen is rejected.

So the open question is not whether a body is accepted. It is whether the body
is **sent correctly**, and whether a second `terraform apply` produces an empty
plan. Only an apply against a real group answers that, and this step does not
apply. Say so rather than implying the question is settled.

Fill in H1, H2 and H3.

Next: `/qg-8-teardown`.
