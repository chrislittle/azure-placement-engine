---
agent: 'Quota Group Collector'
description: 'Step 9: redact, hash and zip the results. Writes nothing.'
---

# Step 9 - package

**Writes nothing.**

Print this block, then wait. Do not run anything until the user
replies with the exact phrase.

```
  STEP 9 - PACKAGE THE RESULTS

  Writes to Azure   NO
  What changes      Nothing in Azure. Writes a zip under output/
  Reversible        Nothing to reverse
  Roles used        None
  API calls         None
  Blast radius      None
  Cost              None

  To run this step, reply exactly:  APPROVE STEP 9
```

---

Before running it, make sure `output/findings.yaml` is as complete as the run
allows. Every answer must cite a file under `captures/`. An answer you cannot
point at does not go in: set it to `null` and leave it.

Ask whether anything extra should be redacted -- an internal project name, a
person's name, a cost centre. The pattern matching catches GUIDs and sign-in
names and nothing else.

```powershell
./scripts/Step09-Package.ps1 -AlsoRedact 'contoso','project-falcon'
```

## Afterwards

Tell the user, in this order:

1. Where the zip is.
2. That `output/redaction-map.local.json` stays on their machine, is
   git-ignored, and is not in the zip. Without it nobody can trace the package
   back to their tenant.
3. That they should read `output/REDACTION.md` before sending, and that the
   decision to send is theirs.

Then summarise what the run answered and what it did not, by section. Be
specific about the gaps: a question nobody reached is more useful recorded as a
gap than quietly left blank.

Do not offer to send the package anywhere. You cannot, and the user should not
be encouraged to treat it as automatic.
