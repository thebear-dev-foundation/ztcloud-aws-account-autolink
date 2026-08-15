@~/.claude/CLAUDE.md

# This repo: ztcloud-aws-account-autolink

Reference Terraform module + Lambda that keeps the Zscaler Connector Portal (ZTW) in sync with an AWS Organization in real time — equivalent to how third-party CNAPP tools detect new and deleted AWS accounts, using Zscaler's OneAPI.

## Stack
- Terraform (`terraform/` — 3 .tf files)
- Python Lambda (`terraform/` — 1 .py file)
- Bash (`scripts/`)
- No Makefile, no CI workflow at root

## Structure
- `README.md` — design + usage doc (load-bearing)
- `ARCHITECTURE.md` — architecture reference
- `CHANGELOG.md`, `LICENSE`
- `terraform/` — module + Lambda implementation
- `scripts/` — operational helpers

## Conventions
- Diff-based reconciliation: every run computes `(Org ∩ tagged) Δ Zscaler` and converges to the delta. Missed events self-heal on the next trigger.
- Opt-in gate: only accounts carrying the configured tag (default `zscaler-managed=true`) are candidates. Core-OU accounts (Management, LogArchive, Audit) are excluded by absence of the tag.
- Managed-prefix name guard: offboarding only deletes Zscaler records whose name begins with the configured prefix (default `ZTW-`). Pre-existing manually-onboarded accounts are NEVER touched.

## Constraints
- TOUCHES PROD: this module syncs a real Zscaler tenant against a real AWS Organization. Apply only after dry-run review.
- Daily safety-net reconciliation runs by default — be aware of its window before manual interventions.
- The opt-in tag and name-prefix guard are load-bearing safety mechanisms — never bypass them.

## Entry points
- Read `README.md` and `ARCHITECTURE.md` first.
- `terraform/` — module entry point (consumer-facing).
- `scripts/` — operational helpers.
