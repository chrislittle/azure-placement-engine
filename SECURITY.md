# Security

## What this project touches

APE reads quota and SKU availability for a subscription, and writes vCPU quota
limits. It does not create, modify or delete any other Azure resource, and it
stores no credentials — both paths use whatever the environment is signed in as,
`az login` locally or OIDC federated credentials in CI.

The identity it runs as needs **Reader** and **Quota Request Operator** on the
target subscription. `Quota Request Operator` is a built-in role scoped to
exactly this job; Contributor works and grants far more than APE needs.

## What must never be committed

Live pool state names a subscription and describes an estate. `.gitignore`
excludes `*.auto.tfvars.json`, `decision.json` and generated `*.bicepparam` for
that reason. If you add a new way to persist read state, add it there too.

## Reporting a vulnerability

Open a private security advisory on the repository rather than a public issue.
