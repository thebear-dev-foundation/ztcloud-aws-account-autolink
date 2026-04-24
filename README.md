# ztcloud-aws-account-autolink

Reference Terraform module + Lambda that keeps the **Zscaler Connector Portal** (ZTW) in sync with an **AWS Organization** in real time — equivalent functionality to how third-party CNAPP tools detect new and deleted AWS accounts, using Zscaler's OneAPI.

## What it does

- Watches the AWS account-vending pipeline (LZA, Control Tower, or custom).
- On a new account in the configured opt-in scope, deploys `ZscalerTagDiscoveryRoleBasic` into that account via CloudFormation StackSet and registers the account with Zscaler via the OneAPI `/ztw/api/v1/publicCloudInfo` endpoint.
- On account removal (or opt-out), deregisters from Zscaler and tears down the discovery role.
- Runs a daily safety-net reconciliation to catch any drift.

## Why

In regulated multi-account AWS Organizations (LZA-TSE, Landing Zone Accelerator, Control Tower), new workload accounts appear continuously through a controlled vending pipeline. Keeping the Zscaler tenant aligned with that Org state by hand is slow and audit-hostile. This module closes the gap: new accounts are inside the Zscaler inspection perimeter within minutes of creation, deregistered accounts are cleaned up automatically, and every action is logged and reviewable.

## Design principles

1. **Diff-based** — computes `(Org ∩ tagged) Δ Zscaler` every run and converges to the delta. Missed events self-heal on the next trigger.
2. **Opt-in gate** — only accounts carrying the configured tag (`zscaler-managed=true` by default) are candidates. Core-OU accounts (Management, LogArchive, Audit) are excluded by the absence of the tag.
3. **Managed-prefix name guard** — offboarding only deletes Zscaler records whose name begins with the configured prefix (default `ZTW-`). Pre-existing manually-onboarded accounts are never touched.
4. **Least-privilege everywhere** — reconciler role scoped to Org read, Secrets Manager read (one ARN), and StackSet ops. Discovery role scoped to read-only EC2/IAM describe.
5. **TSE-compatible** — designed to run in the Audit account with Management-account event forwarding. Management account runs no code.
6. **Dry-run by default** — safe-to-deploy; operator flips to live mode after verification.

## Architecture overview

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design, trust model, security controls, threat model, risk register, and compliance mapping.

```
AWS Organization           Reconciler Lambda          Zscaler OneAPI
(Management)               (Audit account)            (tenant-scoped)

pipeline event ───EB───►   diff Org vs Zscaler ──────► POST /publicCloudInfo
                           │                           (create)
                           │ StackSet CreateStackInstances
                           ▼
                           Workload account ──────────► (Zscaler
                           (opt-in tagged)               assumes role
                           ZscalerTagDiscoveryRole       via external-id)
```

## Repository layout

```
ztcloud-aws-account-autolink/
├── README.md                   — this file
├── ARCHITECTURE.md             — design, security, operations, risk
├── LICENSE                     — Apache 2.0
├── CHANGELOG.md                — version history
├── .env.example                — OneAPI credential template
├── terraform/
│   ├── main.tf                 — Lambda + StackSet + EventBridge + IAM
│   ├── variables.tf            — inputs
│   ├── outputs.tf              — outputs
│   ├── reconciler.py           — reconciler source (embedded in Lambda)
│   ├── discovery_role.yaml     — CFN for ZscalerTagDiscoveryRoleBasic
│   └── cross-account-bus.tf.example — TSE cross-account wiring reference
└── scripts/
    ├── deploy.sh               — deploy wrapper (env, org access, TF apply)
    ├── test.sh                 — interactive E2E against a chosen test account
    └── cleanup.sh              — full teardown
```

## Prerequisites

1. **AWS Organization** with all-features enabled.
2. **AWS CLI + Terraform 1.5+**, authenticated as admin in the account where the Lambda will live (Audit account in TSE deployments; Management works for single-account sandboxes).
3. **Zscaler tenant with OneAPI client** — create an OAuth2 client in ZIdentity scoped minimally to `/ztw/api/v1/publicCloudInfo` (GET, POST, DELETE). Capture `client_id`, `client_secret`, and the vanity domain (format `z-<orgid>.zslogin.net`).
4. **Trusted access for CloudFormation service-managed StackSets** — enabled by the deploy script, or run manually:
   ```bash
   aws organizations enable-aws-service-access \
     --service-principal member.org.stacksets.cloudformation.amazonaws.com
   aws cloudformation activate-organizations-access
   ```

## Quickstart (single-account sandbox)

```bash
# 1. Configure OneAPI creds
cp .env.example .env
# edit .env — populate ZS_VANITY_DOMAIN, ZS_CLIENT_ID, ZS_CLIENT_SECRET

# 2. Deploy (creates Secrets Manager secret + Lambda + StackSet + EventBridge rules)
./scripts/deploy.sh

# 3. Verify dry-run (no side effects)
aws lambda invoke --function-name ztw-reconciler --payload '{}' out.json
cat out.json

# 4. Tag a test account
aws organizations tag-resource --resource-id <TEST_ACCOUNT_ID> \
  --tags Key=zscaler-managed,Value=true

# 5. Flip to live mode and run again
aws lambda update-function-configuration --function-name ztw-reconciler \
  --environment "Variables={...,DRY_RUN=false}"
aws lambda invoke --function-name ztw-reconciler --invocation-type Event --payload '{}' out.json

# 6. Watch CloudWatch Logs
aws logs tail /aws/lambda/ztw-reconciler --follow
```

The E2E cycle (onboard + verify + offboard) takes under 75 seconds against a live AWS Org + Zscaler tenant.

## Production (TSE) deployment

See [ARCHITECTURE.md §8.1](ARCHITECTURE.md#81-deployment) and [`terraform/cross-account-bus.tf.example`](terraform/cross-account-bus.tf.example) for:

- Audit-account deployment
- Management-account event forwarding rule
- Cross-account EventBridge bus
- Customer-managed KMS key for the OneAPI secret
- Lambda in VPC with VPC endpoints
- Egress through Zscaler Cloud Connectors

## Configuration

All behavior is controlled through Terraform variables in [`terraform/variables.tf`](terraform/variables.tf) and Lambda environment variables. See [ARCHITECTURE.md Appendix A](ARCHITECTURE.md#a-environment-variables) for the full table.

Key variables:

| Variable | Default | Purpose |
|---|---|---|
| `pipeline_name` | `AWSAccelerator-Pipeline` | CodePipeline name to hook (LZA default) |
| `stage_name` | `Accounts` | Pipeline stage to watch |
| `target_region` | `ap-southeast-2` | AWS region for discovery role + Zscaler visibility |
| `ztw_region_id` | `1178338` | Zscaler numeric region ID |
| `ztw_region_name` | `AP_SOUTHEAST_2` | Zscaler region enum |
| `opt_in_tag_key` | `zscaler-managed` | Tag key gating onboarding |
| `opt_in_tag_value` | `true` | Tag value required |
| `managed_prefix` | `ZTW-` | Name prefix for records this module may delete |
| `dry_run` | `true` | Safe-by-default; flip to `false` for live mode |

## Security

- **Secrets**: OneAPI credentials stored in AWS Secrets Manager. Customer-managed KMS key strongly recommended for production.
- **Trust**: reconciler Lambda is least-privilege. Discovery role is read-only, external-id-gated, per-account UUID.
- **Egress**: production deployments must route the Lambda's outbound OneAPI calls through Zscaler Cloud Connectors (design detail in ARCHITECTURE.md §5.5).
- **Audit**: every invocation emits a structured result record. Every state transition is in CloudWatch Logs.

See [ARCHITECTURE.md §5 and §10](ARCHITECTURE.md#5-security-model) for the full threat model and risk register.

## Testing

See [ARCHITECTURE.md §9](ARCHITECTURE.md#9-testing--validation) for the formal test plan and live E2E evidence.

Run the interactive test:
```bash
./scripts/test.sh <target-account-id>
```

## Contributing

Please open an issue before submitting a PR for any change to:
- the Lambda permissions boundary
- the discovery role IAM policy
- the OneAPI request shape
- the opt-in tag semantics

These are the security-sensitive surfaces; changes here require review by both the module maintainers and any downstream customer's security team.

## License

Apache License, Version 2.0 — see [LICENSE](LICENSE).

## Disclaimer

This module is a reference implementation. Zscaler provides no warranty. Customers deploying into regulated environments remain responsible for independently validating fitness for purpose, completing their own threat modelling, and applying their organizational controls (KMS CMKs, VPC-attached Lambda, SCPs on tag keys, DLQs, custom metrics, etc.) before production use.
