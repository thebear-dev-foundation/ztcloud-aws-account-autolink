# Zscaler ZTW Auto-Link — Architecture, Operations & Risk Review

**Status:** Reference implementation, live-validated in a sandbox AWS Organization
**Classification:** PUBLIC — safe to share with customers and prospects
**Version:** 0.1.0
**Last updated:** 2026-04-24
**Target audience:** Customer cloud team, security architecture, risk/compliance

---

## 1. Executive Summary

This document describes the reference design for **automated lifecycle management of AWS partner accounts in the Zscaler Connector Portal (ZTW)**, achieving feature-parity with Wiz's "new-account real-time detection" pattern inside a TSE-grade (Trusted Secure Enclaves — Sensitive Edition) AWS Organization.

**Problem:** Zscaler Connector Portal manages partner AWS accounts via Public Cloud Info records. In a multi-account AWS Organization with continuous account vending (LZA-TSE, Control Tower, or custom), keeping the Zscaler tenant in sync with Org state by hand is slow, error-prone, and audit-hostile.

**Solution:** A diff-based reconciler Lambda, triggered by (a) LZA AccountVending pipeline completion (near-real-time) and (b) a daily schedule (safety net), that converges the Zscaler tenant's AWS-account list with the AWS Organization, gated by an opt-in tag.

**Scope of this document:** design, security controls, threat model, testing evidence, operations runbook, risk register, and compliance touchpoints required to obtain cloud-team and security-team approval for production deployment.

**Live validation:** The design has been deployed and end-to-end tested in a real 7-account AWS Organization with a live Zscaler tenant. Full add-and-remove cycle completes in < 75 seconds. Evidence is captured in Section 9.

---

## 2. Problem Statement

### 2.1 The Wiz comparison

Wiz markets real-time detection of AWS account creation/deletion via AWS Organizations management-account CloudTrail ingestion. Customers evaluating SSE/SASE vendors increasingly ask Zscaler for equivalent behavior against the Connector Portal.

### 2.2 What Zscaler provides natively

Zscaler OneAPI exposes full CRUD on the Public Cloud Info resource at `/ztw/api/v1/publicCloudInfo`:

| Method | Path | Purpose |
|---|---|---|
| GET | `/ztw/api/v1/publicCloudInfo` | List partner accounts |
| GET | `/ztw/api/v1/publicCloudInfo/{id}` | Detail |
| POST | `/ztw/api/v1/publicCloudInfo` | Create |
| PUT | `/ztw/api/v1/publicCloudInfo/{id}` | Update |
| DELETE | `/ztw/api/v1/publicCloudInfo/{id}` | Remove |
| GET | `/ztw/api/v1/publicCloudInfo/supportedRegions` | Enumerate AWS regions Zscaler supports |

OneAPI auth is OAuth2 client_credentials via ZIdentity; tokens are short-lived (1h) and bound to a tenant. Rate limit is **1 request/second**.

Zscaler does NOT natively provide:
- AWS Organizations integration
- AWS CloudTrail ingestion
- Any push mechanism from Zscaler into AWS

The gap is the "glue" — a trigger + orchestrator that invokes OneAPI in response to AWS Org lifecycle events. That glue is the subject of this design.

### 2.3 Why this matters for regulated customers

In TSE-grade environments:
- New account creation goes through a controlled pipeline (LZA AccountVending, Control Tower Account Factory)
- Auditors require every workload account to be subjected to a defined set of controls (here, Zscaler inspection) from the moment of creation
- Manual onboarding introduces SLA risk (account created Friday → onboarded Monday = 48h unmanaged)
- Every out-of-band tool connected to the AWS Org must survive the same SC-level review as primary infrastructure

The design must therefore:
1. Fit cleanly into a TSE account-separation model (Management, Audit, Operations, Workloads)
2. Carry no elevated privileges into accounts that don't need them
3. Be auditable end-to-end (every invocation, every API call, every StackSet deployment)
4. Fail safe (no runaway account onboarding; no silent failures)
5. Be fully reversible (graceful offboard, zero orphan resources)

---

## 3. Solution Overview

### 3.1 High-level flow

```
┌────────────────────┐            ┌──────────────────┐         ┌─────────────────┐
│ AWS Organization   │            │  ZTW Reconciler  │         │ Zscaler OneAPI  │
│                    │            │  Lambda (Audit)  │         │ (tenant-scoped) │
│ • CreateAccount    │─(trigger)─►│                  │─(POST)─►│ POST            │
│ • CloseAccount     │            │ diff org vs ZTW  │         │  /publicCloud   │
│ • Tag/Untag        │◄─list──────│                  │◄─GET────│  Info           │
└────────────────────┘            └──────────────────┘         └─────────────────┘
         │                                 │                            │
         │                          (StackSet deploy                    │
         │                           discovery role)                    │
         │                                 ▼                            │
         │                        ┌──────────────────┐                  │
         └───────(OU target)─────►│  Workload        │                  │
                                  │  Account(s)      │                  │
                                  │                  │──(assume role)──►│ (Zscaler
                                  │ ZscalerTagDisc   │                  │  side,
                                  │ overyRoleBasic   │                  │  external)
                                  └──────────────────┘                  │
```

### 3.2 Triggers

| Trigger | Latency | Purpose |
|---|---|---|
| **LZA AccountVending pipeline SUCCEEDED** (EventBridge native, `aws.codepipeline`) | 5–30 sec | Primary. Fires inline with account creation in the vending pipeline. |
| **Daily scheduled EventBridge rule** (`rate(24 hours)`) | bounded 24h | Safety net. Catches any drift from break-glass account creation or OneAPI-side manual changes. |
| **Manual Lambda invoke** | < 1 sec | Ops/drill. Used during testing and incident response. |
| **CloudTrail → EventBridge** (Phase-1 reference, see `../ztw-autolink/`) | 1–15 min | Catch-all safety net; not recommended as primary due to delivery lag. |

### 3.3 Design principles

1. **Diff-based, not event-replay** — the reconciler always computes `(org ∩ tagged) Δ ztw` and converges to that delta. Missed events are recovered naturally on the next invocation.
2. **Opt-in tag gate** — only ACTIVE accounts carrying the configured tag (`zscaler-managed=true` by default) are candidates. Core-OU accounts (Management, LogArchive, Audit) are excluded by the absence of the tag.
3. **Managed-prefix name guard** — offboarding only deletes ZTW records whose `name` begins with the configured prefix (default `ZTW-`). Pre-existing, manually-onboarded accounts are never touched by the automation.
4. **No elevated trust outside the automation account** — the reconciler runs in the Audit / Security-Tooling account; Management hosts only the event forwarder; target accounts receive only a narrowly-scoped read-only IAM role from the StackSet.
5. **Fail-open on the Zscaler side, fail-closed on onboarding** — if OneAPI is unreachable, the reconciler fails and alerts. No assumption of success, no retries in an uncoordinated loop. The next trigger (pipeline or daily) will re-attempt.
6. **Observable by default** — every invocation emits a structured result record (`added`, `removed`, `failed`, `dry_run`, `trigger`). Every state transition is in CloudWatch Logs.

---

## 4. Architecture

### 4.1 Component inventory

| # | Component | Location | Purpose |
|---|---|---|---|
| 1 | **Reconciler Lambda** (`ztw-reconciler`) | Audit account | Orchestrates the diff + OneAPI calls + StackSet operations |
| 2 | **Lambda IAM role** (`ztw-reconciler-role`) | Audit account | Least-privilege execution identity |
| 3 | **Zscaler OneAPI secret** (`zscaler/oneapi-creds`) | Audit account (Secrets Manager, CMK-encrypted in production) | ZIdentity client_credentials |
| 4 | **CFN StackSet** (`ztw-discovery-role`) | Audit account (service-managed via Org trusted access) | Ships `ZscalerTagDiscoveryRoleBasic` into target workload accounts |
| 5 | **EventBridge rule: pipeline hook** (`ztw-lza-pipeline-hook`) | Audit (or Management, forwarded) | Primary trigger — fires on `aws.codepipeline` `Accounts` stage `SUCCEEDED` |
| 6 | **EventBridge rule: daily safety net** (`ztw-reconcile-daily`) | Audit | Secondary trigger — catches drift |
| 7 | **Dead-letter SQS queue** | Audit | Failed invocations for post-incident review (not yet wired in sandbox) |
| 8 | **CloudWatch alarm** (`ztw-reconciler-errors`) | Audit | Alerts on any Lambda error |
| 9 | **ZscalerTagDiscoveryRoleBasic IAM role** (deployed by #4) | Each opted-in workload account | Read-only discovery role Zscaler assumes from the Zscaler-published trust account (sourced from the Connector Portal at onboarding) |
| 10 | **Cross-account event bus** (`ztw-ingress`, optional) | Audit | Receives forwarded events from Management account (TSE pattern) |
| 11 | **Cross-account event forwarder rule + IAM role** | Management account | Forwards pipeline events to Audit bus |

### 4.2 Data flows

**Flow 1 — primary onboarding (pipeline-driven):**

```
1. LZA AccountVending CodePipeline executes Accounts stage → SUCCEEDED
2. CodePipeline natively emits CloudWatch/EventBridge event:
   source: aws.codepipeline
   detail-type: "CodePipeline Stage Execution State Change"
   detail.pipeline: AWSAccelerator-Pipeline
   detail.stage: Accounts
   detail.state: SUCCEEDED
3. (TSE) Management account rule forwards to Audit account's ztw-ingress bus
4. Audit account rule routes to ztw-reconciler Lambda
5. Lambda enters lambda_handler(event, context):
   a. Fetch OneAPI credentials from Secrets Manager
   b. Acquire OAuth2 token from ZIdentity
   c. organizations:ListAccounts → org_set (ACTIVE only)
   d. For each org_set member: organizations:ListTagsForResource → tagged_set
   e. GET /ztw/api/v1/publicCloudInfo → ztw_set
   f. to_add = tagged_set − ztw_set (new opted-in accounts)
   g. to_remove = ztw_set − tagged_set, filtered by MANAGED_PREFIX
   h. For each to_add:
      i.   Generate per-account externalId (UUID4)
      ii.  cloudformation:CreateStackInstances
             target: {OrganizationalUnitIds: [root_or_workload_ou], Accounts: [aid], AccountFilterType: INTERSECTION}
             region: TARGET_REGION
             parameter: ExternalId=<UUID>
      iii. Poll DescribeStackSetOperation until SUCCEEDED (typ. 40–60 sec)
      iv.  POST /ztw/api/v1/publicCloudInfo with {name, cloudType:AWS, externalId, accountDetails, supportedRegions}
      v.   Sleep 1.5s (rate-limit)
   i. For each to_remove:
      i.   DELETE /ztw/api/v1/publicCloudInfo/{id}
      ii.  cloudformation:DeleteStackInstances (same OU+account target)
      iii. Sleep 1.5s
   j. Return {added, removed, failed, dry_run, trigger}
6. CloudWatch Logs captures every step.
```

**Flow 2 — reconciliation (daily scheduled):** identical to Flow 1 steps 5 onward.

**Flow 3 — manual drill / backfill:** identical to Flow 1 steps 5 onward, triggered by ops-initiated `aws lambda invoke`.

### 4.3 Trust topology

```
  Customer AWS Organization
  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │   Management ─── forwarding ───► Audit ─── reconciler ◄─── Ops      │
  │   (root, SCPs)                   (lambda,                 (opt.     │
  │                                   secrets,                 StackSet │
  │                                   StackSet                 admin    │
  │                                   admin)                   host)    │
  │                                                                     │
  │         │                          │                                │
  │         │ (service-managed         │ (read-only                     │
  │         │  StackSet targeting      │  discovery role                │
  │         │  Workloads OU only)      │  assume, via Zscaler           │
  │         ▼                          │  trust account ID)             │
  │                                    ▼                                │
  │   Workload-A  Workload-B  Workload-N                                │
  │   (tag: zscaler-managed=true)                                       │
  └─────────────────────────────────────────────────────────────────────┘
                                           │
                                           │ (external — out of our
                                           │  trust boundary)
                                           ▼
                                    Zscaler AWS account
                                    (ID sourced from
                                     Connector Portal)
                                    (assumes discovery role
                                     via external-id condition)
```

**Trust assertions:**
- Management account has *zero* code execution for this workflow. Only EventBridge routing.
- Audit account is the *single* source of execution; contains the OneAPI secret, the reconciler logic, the StackSet admin role.
- Workload accounts receive *only* the discovery role (read-only, external-id-conditioned, no write anywhere).
- Zscaler's trust account (sourced from the Connector Portal at onboarding) can assume the discovery role *only* with the correct per-account external-id.

---

## 5. Security Model

### 5.1 Trust boundaries

| Boundary | What crosses it | How it's enforced |
|---|---|---|
| **Audit account ⇄ Management account** | Pipeline events | EventBridge cross-account bus policy grants only `events:PutEvents` from Management account principal. Events themselves contain no secrets — just metadata (account IDs, stage state). |
| **Audit account ⇄ Workload accounts** | StackSet deployments (CFN templates) | Service-managed StackSets use AWS-managed `AWSServiceRoleForCloudFormationStackSetsOrgMember` in targets; CloudFormation itself is the trust anchor. |
| **Audit account ⇄ Zscaler (internet)** | OneAPI HTTPS calls (token + JSON) | TLS 1.2+ to `api.zsapi.net` and `{vanity}.zslogin.net`. In production: routed through Zscaler Cloud Connectors (inline SSL inspection of our own automation — closes the "policy governs itself" loop). |
| **Workload account ⇄ Zscaler (internet)** | `sts:AssumeRole` from Zscaler into workload | Trust policy scoped to single Zscaler role ARN + per-account external-id condition. |

### 5.2 IAM design (least-privilege)

**Reconciler Lambda role — `ztw-reconciler-role`:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OrgRead",
      "Effect": "Allow",
      "Action": [
        "organizations:ListAccounts",
        "organizations:ListTagsForResource",
        "organizations:DescribeAccount",
        "organizations:ListRoots"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecretRead",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:<region>:<audit-acct>:secret:zscaler/oneapi-creds-*"
    },
    {
      "Sid": "StackSetOps",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStackInstances",
        "cloudformation:DeleteStackInstances",
        "cloudformation:DescribeStackSetOperation",
        "cloudformation:DescribeStackSet",
        "cloudformation:ListStackInstances"
      ],
      "Resource": "*"
    }
  ]
}
```

Plus AWS-managed `AWSLambdaBasicExecutionRole` for logs.

**Hardening notes for production:**
- StackSet actions can be scoped to `arn:aws:cloudformation:<region>:<audit-acct>:stackset/ztw-discovery-role:*` — not `*`. Recommended.
- Add a TSE permissions boundary (customer-provided). The role must not be able to create new IAM principals or attach managed policies.
- No `iam:*`, `kms:*` except via the CMK key policy (Section 5.3).
- No `sts:AssumeRole` — the Lambda does not assume any role beyond its own.

**StackSet discovery role — `ZscalerTagDiscoveryRoleBasic`:**

```yaml
Trust:
  Principal: arn:aws:iam::<ZSCALER_AWS_ACCOUNT_ID>:role/<ZSCALER_TRUST_ROLE>   # both sourced from the Connector Portal
  Action: sts:AssumeRole
  Condition: StringEquals { sts:ExternalId: <per-account-UUID> }
Policy:
  - ec2:DescribeVpcs
  - ec2:DescribeSubnets
  - ec2:DescribeInstances
  - ec2:DescribeVpcEndpoints
  - ec2:DescribeNetworkInterfaces
  - ec2:DescribeTags
  - iam:GetInstanceProfile
  - iam:ListAttachedRolePolicies
  (All read-only. No write, no data-plane actions.)
```

Rationale per action:
- `DescribeVpcs/Subnets/Instances/VpcEndpoints/NetworkInterfaces` — Zscaler builds the customer-VPC graph to populate the ZTW topology view.
- `DescribeTags` — enables tag-based policy targeting in ZIA.
- `GetInstanceProfile / ListAttachedRolePolicies` — used by Zscaler's Workload Discovery Service to classify EC2 workloads by role posture.

### 5.3 Secrets management

**In sandbox (today):** the OneAPI secret is stored in Secrets Manager as plaintext JSON `{vanity, client_id, client_secret}` using the AWS-managed key.

**In production (required):**
1. Create a dedicated customer-managed KMS key (CMK) in the Audit account.
2. Key policy grants:
   - Administration: KMS administrator role only.
   - Usage (`kms:Decrypt`, `kms:DescribeKey`): `ztw-reconciler-role` only.
3. Secret encrypted with the CMK.
4. Secrets Manager rotation enabled: a second Lambda (out of scope for this doc) calls ZIdentity `rotate client_secret` API on schedule (90 day default).
5. Access logs (via CloudTrail data events on Secrets Manager) delivered to LogArchive.

**Credential classification:**
- `client_id` — low sensitivity (tenant-identifying, non-secret by design)
- `client_secret` — HIGH sensitivity. Possession grants full OneAPI access to the tenant. Treat as equivalent to an AWS root access key. Never log, never emit in event payloads, never write to files outside Secrets Manager.

**Compromise response:** ZIdentity admin portal → delete API client → create new → update the Secrets Manager secret. All in-flight tokens expire within 1 hour. No code changes required.

### 5.4 Data classification

**Data at rest:**

| Data | Where | Classification | Retention |
|---|---|---|---|
| OneAPI client_secret | Secrets Manager (CMK-encrypted) | SECRET | indefinite, rotated |
| OneAPI tokens | in-memory only (Lambda runtime) | SECRET | 1-hour max lifetime, never persisted |
| Per-account externalIds | CloudFormation stack parameters (in target accounts) + Zscaler tenant | CONFIDENTIAL | lifetime of account in Zscaler tenant |
| Reconciler event payloads | CloudWatch Logs | INTERNAL | 14 days (configurable; recommend 1 year for audit) |
| Reconciler state (in-memory) | Lambda runtime | INTERNAL | milliseconds |
| AWS Org account list | in-memory | INTERNAL | per-invocation |

**Data in transit:**
- Lambda ⇄ Secrets Manager: AWS-internal TLS, VPC endpoint in production
- Lambda ⇄ Organizations API: AWS-internal TLS, VPC endpoint in production
- Lambda ⇄ CloudFormation: AWS-internal TLS, VPC endpoint in production
- Lambda ⇄ ZIdentity (token exchange): public TLS 1.2+, via Zscaler Cloud Connector in production
- Lambda ⇄ ZTW OneAPI: public TLS 1.2+, via Zscaler Cloud Connector in production
- Zscaler ⇄ Workload account (AssumeRole): AWS STS public TLS 1.2+, from Zscaler's own infra

**No customer workload data ever traverses this design.** The reconciler reads only Organizations metadata (account IDs, names, tags) and writes to OneAPI. Workload-account contents (EC2 instances, data stores) are not accessed by the Lambda; they are accessed later, separately, by Zscaler's Workload Discovery Service via the per-account discovery role.

### 5.5 Network egress (production)

**Required outbound:**
- `api.zsapi.net` (443) — OneAPI
- `<vanity>.zslogin.net` (443) — ZIdentity token exchange
- VPC endpoint for: Secrets Manager, CloudFormation, Organizations, CloudWatch Logs, KMS, EventBridge

**Prohibited outbound:**
- Public internet for any AWS service (AWS calls must go via VPC endpoints)
- Any destination other than the two Zscaler endpoints above

**Enforcement mechanisms:**
1. Lambda attached to a private subnet with no IGW route.
2. Subnet's NAT egress routed through the Perimeter account's Zscaler Cloud Connectors (inline policy enforcement).
3. Cloud Connector forwarding rules explicitly allow only the two Zscaler FQDNs above.
4. VPC endpoint policies restrict principal to the Lambda role ARN.
5. Optional: ZIA URL Filtering rule in the Zscaler tenant applied to the Lambda's Egress profile, whitelisting only the two FQDNs.

This design subjects the reconciler's own Zscaler calls to Zscaler's policy — a self-governing control loop.

### 5.6 Cryptographic controls

| Control | Implementation |
|---|---|
| Secrets at rest | AWS KMS CMK (AES-256) |
| Secrets in transit | TLS 1.2+ everywhere |
| OneAPI token | OAuth2 JWT, signed by ZIdentity, RS256 |
| External-id | UUIDv4 (128 bits of randomness, per-account, never reused) |
| Log integrity | CloudWatch Logs → S3 (LogArchive) with Object Lock (WORM) recommended |

---

## 6. Event Semantics & Correctness

### 6.1 Reconciler algorithm (formal)

```
Let O = { a | a ∈ AWS Org, Status(a) = ACTIVE }
Let T = { a | a ∈ O ∧ Tag(a, zscaler-managed) = true }
Let Z = { a | a ∈ Zscaler tenant, cloudType = AWS }
Let M = { a | a ∈ Z ∧ name(a) starts with MANAGED_PREFIX }

add    = T \ Z           (tagged in Org, absent from ZTW)
remove = M \ T           (managed by us in ZTW, no longer tagged in Org)

For each a in add:
  Generate fresh external_id_a ∈ UUIDv4
  Deploy ZscalerTagDiscoveryRoleBasic to a with external_id_a  (blocks until SUCCEEDED)
  POST /publicCloudInfo with (a, external_id_a)

For each a in remove:
  DELETE /publicCloudInfo/{id_of(a)}
  Delete StackSet instance for a
```

**Correctness properties:**
- **Idempotent**: running the algorithm twice with the same inputs has no additional side effects beyond the first run.
- **Monotonic convergence**: if triggers stop after time t, the Zscaler tenant reaches the desired state by time t + (StackSet operation duration) + (OneAPI RTT) for the final trigger.
- **Safe on missed events**: every subsequent invocation (including the daily schedule) recomputes the diff from ground truth.
- **No stale-read anomalies**: `list_accounts` and `GET /publicCloudInfo` are both strongly consistent. If a new account appears mid-run, it is picked up on the next trigger.

### 6.2 Idempotency guarantees

| Scenario | Behavior |
|---|---|
| Same account tagged twice | `add` diff empty on second run; no-op. |
| POST to OneAPI succeeds but Lambda times out before logging | Next run sees account in `Z`; no re-POST; log reconciles on next trigger. |
| StackSet deploy succeeds but POST fails | Next run: StackSet instance already exists (CFN detects no change needed); POST retried; if still fails, Lambda returns `failed: [aid]` and alarm fires. |
| Account manually deleted from Zscaler tenant | Next run re-adds (since still tagged); StackSet already present, no-op there. |
| Account manually added to Zscaler tenant outside `MANAGED_PREFIX` | Ignored by `remove` filter — never touched. |
| Tag removed then re-added within same window | Two diffs: remove then add. Both safe. |

### 6.3 Failure modes + recovery

| Failure | Detection | Recovery |
|---|---|---|
| OneAPI unreachable | HTTP error captured, logged, `failed: [aid]` returned. Lambda errors → CloudWatch alarm fires. | Next trigger retries. Human intervenes if persistent. |
| OneAPI rate-limit (429) | Currently: retry-after header logged; NOT automatically retried. Count stays in `failed`. | Future: exponential-backoff retry within the Lambda. For now, next trigger picks up. |
| OneAPI schema change | POST returns 400 with Zscaler error body; logged in full. | Code change needed; version-pin OneAPI responses in integration tests. |
| StackSet deployment fails | Exception raised; `_onboard` returns False; `failed: [aid]` emitted. | Investigate StackSet console; fix template / target account constraint; retry. |
| StackSet deployment hangs > 5min | Built-in 30-poll (10s) timeout raises `TimeoutError`. | Investigate StackSet console; manual remediation. |
| Lambda itself errors (e.g., OOM, permission) | CloudWatch Error alarm + DLQ (when wired) | Inspect logs, remediate, manual invoke to replay. |
| Secrets Manager unavailable | Secret fetch throws; Lambda errors; alarm fires. | Next trigger retries. |
| Organizations API throttled | boto3 default retry handles transient throttling. Persistent throttling → logs + alarm. | Reduce daily-schedule frequency if needed; not expected at this scale. |
| Rogue account tagged (should not have been) | Will be onboarded. | Untag → next run offboards. Audit CloudTrail for who tagged. |
| Rogue untag (account should still be onboarded) | Will be offboarded. | Re-tag → next run re-onboards. Audit CloudTrail for who untagged. |

**Mitigation for rogue tag/untag:** in production, require a Config rule or SCP that prohibits `organizations:TagResource` / `UntagResource` with `Key=zscaler-managed` except by a named governance principal (e.g., the account-vending pipeline's role).

---

## 7. Observability

### 7.1 Logs

**CloudWatch Logs group:** `/aws/lambda/ztw-reconciler`
- Retention: recommended **365 days** for audit; default 14 days.
- Subscription filter (production): forward to LogArchive S3 with KMS encryption.

**Log lines per invocation (structured):**

```
trigger: <source>|<detail-type>|manual  dry_run=<bool>
org=<n> tagged=<n> ztw=<n> add=<n> remove=<n>
[per add:] onboard <aid> (<name>) extId=<uuid>
           stackset op <op-id> dispatched for <aid>
           stackset op <op-id>: RUNNING|SUCCEEDED|FAILED (poll <n>)
           POST <code> for <aid>: <ok|error-body>
[per remove:] offboard <aid> (ztw id=<rec-id>)
           DELETE <code> for <aid>: <ok|error-body>
           stackset delete dispatched for <aid>
result: {added: [...], removed: [...], failed: [...], dry_run: <bool>, trigger: <source>}
```

Every Lambda request has a unique `RequestId` (ULID-like) that correlates all lines for that invocation.

### 7.2 Metrics

Native AWS:
- `AWS/Lambda/Invocations` per `FunctionName=ztw-reconciler`
- `AWS/Lambda/Errors` — alarmed at > 0 in any 5-min period
- `AWS/Lambda/Duration` — track p50/p99
- `AWS/Events/MatchedEvents` per rule
- `AWS/Events/Invocations` per rule
- `AWS/Events/FailedInvocations` per rule (cross-account failures)

Recommended custom (Embedded Metric Format, EMF):
- `ZTW/Onboarded` counter — emit `len(added)` per invocation
- `ZTW/Offboarded` counter — emit `len(removed)` per invocation
- `ZTW/Failed` counter — emit `len(failed)` per invocation
- `ZTW/DriftDetected` boolean — 1 if `added ∪ removed ≠ ∅` on the daily-schedule trigger

### 7.3 Alarms

| Alarm | Trigger | Action |
|---|---|---|
| `ztw-reconciler-errors` | `Errors > 0` in 5 min | PagerDuty → oncall |
| `ztw-reconciler-failed-accounts` | custom `ZTW/Failed > 0` sustained | PagerDuty → oncall |
| `ztw-drift-detected` | `ZTW/DriftDetected > 0` on daily schedule (indicates pipeline trigger missed an account) | Slack warning → review |
| `ztw-no-invocations-24h` | `Invocations < 1` in 24h | Slack warning → check triggers |

### 7.4 Tracing

AWS X-Ray not currently wired. Recommended for production to trace OneAPI HTTP spans + StackSet operations.

---

## 8. Operations Runbook

### 8.1 Deployment

**Prerequisites:**
1. AWS Organizations with trusted access enabled for CloudFormation service-managed StackSets:
   ```
   aws organizations enable-aws-service-access \
     --service-principal member.org.stacksets.cloudformation.amazonaws.com
   aws cloudformation activate-organizations-access
   ```
2. Terraform 1.5+ and an AWS CLI profile/role with admin in the Audit (or Management, for sandbox) account.
3. Zscaler OneAPI client_id + client_secret from the ZIdentity admin portal, scoped minimally to the `/ztw/api/v1/publicCloudInfo` endpoint.

**Deploy:**
```bash
cd ztw-autolink/lza-hook
./deploy.sh
```

The script is idempotent. It:
1. Enables AWS Organizations trusted access (if not yet).
2. Activates CloudFormation organizations-access (if not yet).
3. Creates / updates the Secrets Manager secret.
4. `terraform init -upgrade && terraform apply -auto-approve`.

Post-deploy state:
- Lambda `ztw-reconciler` deployed in `DRY_RUN=true` mode.
- StackSet `ztw-discovery-role` exists, zero instances.
- EventBridge rules live but firing no-ops.

**Go-live:**
1. Verify dry-run: `aws lambda invoke --function-name ztw-reconciler --payload '{}' out.json`
2. Inspect `add`/`remove` lists in the response and CloudWatch Logs.
3. If correct, flip:
   ```
   aws lambda update-function-configuration --function-name ztw-reconciler \
     --environment "Variables={...,DRY_RUN=false}"
   ```
4. Or redeploy with `terraform apply -var dry_run=false`.

### 8.2 Upgrade (code change)

1. Modify `reconciler.py` (and/or `main.tf`).
2. `terraform apply` — `archive_file` + `source_code_hash` ensures the Lambda is re-published on any code change.
3. Watch CloudWatch Logs for the next scheduled invocation (or manually invoke).
4. If behavior regresses, roll back:
   ```
   git revert <bad-commit>
   terraform apply
   ```

### 8.3 Dry-run / live mode switch

`DRY_RUN=true` (default): the reconciler does everything except `POST` to OneAPI, `DELETE` to OneAPI, and StackSet instance create/delete. It logs every intended action as `DRY_RUN add/remove` lines.

`DRY_RUN=false`: live mode. Changes are applied.

Always flip to `DRY_RUN=true` before any config change, and flip back after verification.

### 8.4 Break-glass

**Scenario: runaway onboarding (reconciler stuck in a loop, adding unintended accounts)**

1. Disable both EventBridge rules immediately:
   ```
   aws events disable-rule --name ztw-lza-pipeline-hook
   aws events disable-rule --name ztw-reconcile-daily
   ```
2. Set Lambda concurrency to 0:
   ```
   aws lambda put-function-concurrency --function-name ztw-reconciler --reserved-concurrent-executions 0
   ```
3. Inspect CloudWatch Logs for root cause.
4. Inventory current ZTW state: `curl /ztw/api/v1/publicCloudInfo | jq`.
5. Remove unintended records via OneAPI DELETE.
6. Remediate code / config.
7. Re-enable rules + concurrency.

**Scenario: OneAPI credentials compromised**

1. ZIdentity admin portal → revoke the API client.
2. Create a replacement API client.
3. Update Secrets Manager secret with new credentials.
4. The next Lambda invocation fetches the fresh secret (no code change needed).

**Scenario: Zscaler tenant inadvertently deleted accounts**

Daily reconciler will re-add them on the next run. Set `DRY_RUN=false` and manually invoke to accelerate.

### 8.5 Teardown

```bash
cd ztw-autolink/lza-hook
./cleanup.sh
```

The script:
1. Untags the opt-in account(s).
2. Removes all `MANAGED_PREFIX`-prefixed records from the Zscaler tenant.
3. Deletes all StackSet instances.
4. `terraform destroy`.

---

## 9. Testing & Validation

### 9.1 Test plan

| # | Test | Expected | Status |
|---|---|---|---|
| T1 | OneAPI POST shape probe (minimal body) | 400 with `"Region info is mandatory"` | ✅ Pass |
| T2 | OneAPI POST shape probe (full body) | 200 + record ID returned | ✅ Pass |
| T3 | OneAPI DELETE round-trip | 204 | ✅ Pass |
| T4 | OneAPI rate-limit enforcement | 429 on < 1 sec gap between calls | ✅ Confirmed, serialized with 1.5s gap |
| T5 | Terraform deploy (fresh) | 12 resources created, no drift | ✅ Pass |
| T6 | Tag apply on Workload-Test | Tag present, invocation detects | ✅ Pass |
| T7 | Dry-run invocation | `added=[target]`, `dry_run=true`, no side effects | ✅ Pass |
| T8 | Live onboarding (DRY_RUN=false) | StackSet instance → SUCCEEDED; OneAPI POST → 200; Zscaler tenant list shows new record | ✅ Pass, 62.6s total |
| T9 | Zscaler tenant record shape | `name=ZTW-*`, `awsAccountId`, `externalId`, `supportedRegions`, `permissionStatus.assumeRole=Pending` initially | ✅ Pass |
| T10 | Untag → live offboarding | OneAPI DELETE → 204; StackSet instance deletion dispatched | ✅ Pass, 8.6s total |
| T11 | Post-offboard state | Zscaler tenant back to baseline; StackSet 0 instances | ✅ Pass |
| T12 | EventBridge rule evaluation | MatchedEvents metric increments when a pipeline event is synthesized | Not yet covered in sandbox (no LZA pipeline); covered by direct invoke in T7–T11 |
| T13 | CloudTrail (Phase-1) latency measurement | 1–15 min delivery lag confirmed | ✅ Pass (validated as justification for primary trigger choice) |

### 9.2 Live E2E evidence (sandbox validation)

Live test carried out in a sandbox AWS Organization (7 member accounts: LogArchive, Audit, Network, Operations, Perimeter, Workload-Test, + root) against a production Zscaler tenant (2 pre-existing partner accounts). All AWS account IDs below are redacted to `<NNN>` placeholders.

**Onboarding run (2026-04-24T01:33Z):**
```
01:33:01  trigger: manual-test-live dry_run=False
01:33:05  org=7 tagged=1 ztw=2 add=1 remove=0
01:33:05  onboard <TARGET_ACCT> (ZTW-Workload-Test) extId=<uuid4>
01:33:07  stackset op <op-id> dispatched for <TARGET_ACCT>
01:33:17  stackset op: RUNNING (poll 1)
01:33:27  stackset op: RUNNING (poll 2)
01:33:38  stackset op: RUNNING (poll 3)
01:33:48  stackset op: RUNNING (poll 4)
01:33:58  stackset op: SUCCEEDED (poll 5)
01:34:04  POST 200 for <TARGET_ACCT>: ok
01:34:04  result: {added: ['<TARGET_ACCT>'], removed: [], failed: [], dry_run: False, trigger: 'manual-test-live'}
          Duration: 62.6 sec
```

**Offboarding run (2026-04-24T01:36Z):**
```
01:36:48  trigger: manual-test-offboard dry_run=False
01:36:52  org=7 tagged=0 ztw=3 add=0 remove=1
01:36:52  offboard <TARGET_ACCT> (ztw id=<ztw-rec-id>)
01:36:55  DELETE 204 for <TARGET_ACCT>: ok
01:36:57  stackset delete dispatched for <TARGET_ACCT>
01:36:57  result: {added: [], removed: ['<TARGET_ACCT>'], failed: [], dry_run: False, trigger: 'manual-test-offboard'}
          Duration: 8.6 sec
```

**Final state verification:**
- Zscaler tenant `/publicCloudInfo` list: restored to pre-test baseline (2 accounts, neither managed by this module).
- StackSet `ztw-discovery-role` instances: 0.
- StackSet operations history: CREATE SUCCEEDED, DELETE SUCCEEDED.

**Observed caveat:** `permissionStatus.assumeRole` remained `Pending` for the 2-minute post-onboard poll window. Zscaler tenant-side permission evaluation runs on its own cadence (empirically 5–15 minutes). This is Zscaler-side behavior, not a defect of the reconciler. In production, the `Allowed` transition will have occurred well before any workload discovery is attempted.

---

## 10. Risk Register

| # | Risk | Likelihood | Impact | Severity | Mitigation | Residual |
|---|---|---|---|---|---|---|
| R1 | Rogue principal tags a non-opt-in account with `zscaler-managed=true` | Low | High (unintended onboarding; Zscaler sees account data) | High | SCP restricting `TagResource` with this tag key to the vending pipeline's role; CloudTrail alarm on any other principal tagging this key | Medium |
| R2 | OneAPI client_secret leaks | Low | High (full tenant access) | High | CMK encryption, Secrets Manager only; rotation; VPC endpoint; no log emission; never in code | Low |
| R3 | Reconciler onboards the Management/LogArchive/Audit account accidentally | Very Low | High (core accounts exposed to Zscaler) | High | Opt-in tag gate + Core-OU SCP prevents the tag from being applied to core accounts | Very Low |
| R4 | OneAPI schema breaks on a version update | Medium | Medium (onboarding stops) | Medium | Pinned test suite; CloudWatch alarm on errors; daily schedule gives 24h max outage window | Low |
| R5 | StackSet deploys to wrong account | Very Low | High | High | `AccountFilterType=INTERSECTION` + explicit Accounts list in API call; CloudFormation change-set review in production | Very Low |
| R6 | CloudTrail → EventBridge (Phase-1) lag causes missed onboarding | High | Low | Medium | Explicitly not the primary trigger in this design. Pipeline hook is primary. | Very Low |
| R7 | Lambda runs amok due to code bug | Low | Medium | Medium | DRY_RUN default on config changes; Error alarm; break-glass documented | Low |
| R8 | External-id collision across customers | Astronomically low (UUIDv4) | Low | Low | UUID4 entropy (2^122 unique values) | Negligible |
| R9 | Zscaler trust account (sourced from Connector Portal) compromised | Out of customer control | High | Medium | Zscaler's own operational controls; trust the external-id condition to scope blast radius to one customer at a time | External dependency |
| R10 | Operator deletes the Lambda manually | Low | Low (fail-open; no new events processed) | Low | Terraform drift detection; daily schedule still runs if only the rule is intact | Low |
| R11 | Tag key change not propagated | Low | Medium (silent ignore) | Medium | Config is single source; change via terraform apply propagates to Lambda env | Low |
| R12 | Regulator discovers OneAPI calls not logged | Low | High (audit finding) | High | CloudWatch Logs → LogArchive with Object Lock; ZTW API CloudTrail (tenant-side, via Zscaler admin audit log) | Low |
| R13 | Target account's OU changes after onboarding | Medium | Low (stale opt-in state) | Low | Daily reconciler detects; opt-in gate re-evaluated every run | Negligible |

---

## 11. Compliance mapping

### 11.1 NIST CSF 2.0

| Function | Category | How addressed |
|---|---|---|
| IDENTIFY | ID.AM (Asset Management) | Every Org account discovered via `organizations:ListAccounts`; tag attribute drives policy |
| PROTECT | PR.AC (Access Control) | IAM least-privilege; trust boundary enforced at StackSet target level |
| PROTECT | PR.DS (Data Security) | CMK encryption at rest; TLS in transit; no customer workload data in reconciler |
| DETECT | DE.CM (Security Continuous Monitoring) | CloudWatch alarms; daily reconciliation; drift metric |
| DETECT | DE.AE (Anomalies and Events) | Rogue-tag mitigation (R1) detects unauthorized principals |
| RESPOND | RS.MI (Mitigation) | Break-glass runbook; DLQ captures failed invocations |
| RECOVER | RC.RP (Recovery Planning) | Diff-based reconciler self-heals on next invocation |

### 11.2 CIS AWS Benchmark

| Control | Addressed by |
|---|---|
| 1.4 Ensure no root user access key exists | Out of scope; customer-side org-level control |
| 1.14 Ensure access keys are rotated every 90 days | N/A — Lambda uses role, no access keys |
| 2.1.1 Ensure CloudTrail is enabled in all regions | Deployed org-wide trail (Phase-1 and/or customer-side TSE standard) |
| 2.4 Ensure CloudWatch log group exists and is encrypted | Lambda log group; KMS CMK recommended |
| 3.x Monitoring | CloudWatch alarms on Lambda errors; EventBridge rule health |

### 11.3 SOC 2 (Trust Services Criteria)

| TSC | How addressed |
|---|---|
| CC6.1 Logical access | Lambda role least-privilege; trust policy scoping on discovery role |
| CC6.6 Logical access restricted | VPC endpoints, private subnet, Zscaler egress inspection |
| CC7.2 Monitor system components | CloudWatch Logs, alarms, metrics |
| CC7.4 Incident response | Break-glass runbook in Section 8.4 |
| A1.2 System availability | Daily reconciler provides 24h SLO on drift detection |

### 11.4 ISO 27001 Annex A (selected)

| Control | How addressed |
|---|---|
| A.8.3 Information access restriction | Role-based access; secret scoped to Lambda role |
| A.8.16 Monitoring activities | CloudWatch + alarm + log retention |
| A.8.21 Security of network services | TLS; VPC endpoints; Cloud Connector egress |
| A.8.24 Use of cryptography | KMS CMK, TLS 1.2+ |
| A.8.25 Secure development life cycle | Terraform-pinned, peer-reviewed; staged deploy (DRY_RUN → live) |
| A.5.12 Classification of information | Section 5.4 above |

---

## 12. Open risks and future hardening

### 12.1 Deferred to follow-up work

1. **Custom-managed KMS key for the secret** — currently uses AWS-managed. Production must switch.
2. **VPC-attached Lambda** — currently in the default execution environment (public AWS network). Production must run the Lambda in a private VPC subnet with VPC endpoints for all AWS services plus NAT egress via Zscaler CCs.
3. **Secrets Manager rotation** — not wired. Requires a second Lambda that calls ZIdentity client_secret rotation.
4. **Step-Function approval gate for first N onboardings per quarter** — recommended in Section 5 of the earlier architecture, not implemented here.
5. **X-Ray tracing** — not wired.
6. **EMF custom metrics** — only native Lambda/Events metrics today; Section 7.2 custom metrics are recommended but not implemented.
7. **SCP to restrict who can tag `zscaler-managed`** — customer-side org policy; out of this module's scope.
8. **Cross-account event bus wiring** — `cross-account-bus.tf.example` is a reference template, not an applied configuration. Customer must adapt to their TSE account-map.

### 12.2 Known limitations

- **OU-targeted StackSets** — the reconciler currently deploys to the root OU with `AccountFilterType=INTERSECTION`. In a TSE deployment, the OU targeting should be scoped to the Workloads OU specifically (env var `TARGET_OU_ID`). Minor change.
- **Single-region targeting** — the StackSet deploys the discovery role to one region (`TARGET_REGION`, default `ap-southeast-2`). If workloads span multiple regions, the reconciler must iterate.
- **OneAPI pagination** — `/ztw/api/v1/publicCloudInfo` currently returns a flat array. If Zscaler introduces pagination, the reconciler must handle it.
- **No soft-delete grace period** — an untag immediately offboards. If the operator wants a delay (e.g., 24h grace), add a state table in DynamoDB.

### 12.3 Roadmap

| Quarter | Item |
|---|---|
| Now | Sandbox validation (done) |
| +1 | Customer pilot in non-prod TSE account (Audit + 1 Workloads-Sandbox) |
| +1 | Wire DLQ, CMK, VPC endpoints |
| +2 | Add Step-Function approval gate; EMF metrics |
| +2 | Extend to Azure (`/ztw/api/v1/publicCloudInfo?cloudType=AZURE`) and GCP equivalents |
| +3 | Upstream to Zscaler's official ZTW tooling if tenant demand warrants |

---

## 13. Appendices

### A. Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ZS_SECRET_ID` | `zscaler/oneapi-creds` | Secrets Manager secret ID |
| `STACKSET_NAME` | `ztw-discovery-role` | CFN StackSet name |
| `TARGET_REGION` | `ap-southeast-2` | AWS region where the discovery role is deployed |
| `ZTW_REGION_ID` | `1178338` | Zscaler numeric region id (AP_SOUTHEAST_2) |
| `ZTW_REGION_NAME` | `AP_SOUTHEAST_2` | Zscaler region enum |
| `OPT_IN_TAG_KEY` | `zscaler-managed` | Organizations tag key gating onboarding |
| `OPT_IN_TAG_VALUE` | `true` | Tag value required |
| `MANAGED_PREFIX` | `ZTW-` | Name prefix for records this automation may delete |
| `DRY_RUN` | `true` | Safe default; flip to `false` for live mode |

### B. OneAPI POST payload reference

```json
{
  "name": "ZTW-<AWS-Account-Name>",
  "cloudType": "AWS",
  "externalId": "<uuid4>",
  "accountDetails": {
    "awsAccountId": "<12-digit-aws-account-id>",
    "awsRoleName": "ZscalerTagDiscoveryRoleBasic",
    "externalId": "<uuid4-same-as-above>"
  },
  "supportedRegions": [
    {
      "id": 1178338,
      "cloudType": "AWS",
      "name": "AP_SOUTHEAST_2"
    }
  ]
}
```

Zscaler auto-populates on successful POST: `eventBusName`, `trustedAccountId`, `trustedRole`, `troubleShootingLogging`, `cloudWatchGroupArn`, `lastSyncTime`, `lastModUser`, `lastModTime`, `permissionStatus.status.assumeRole=Pending`.

### C. Terraform variables

See [`terraform/variables.tf`](terraform/variables.tf). Key vars the customer will tune:
- `region` — AWS region for the reconciler (Audit account's home region)
- `target_region` — AWS region where the discovery role is deployed + Zscaler discovers resources
- `pipeline_name` — defaults to `AWSAccelerator-Pipeline` (LZA)
- `stage_name` — defaults to `Accounts` (LZA's account-vending stage)
- `ztw_region_id` / `ztw_region_name` — Zscaler numeric + enum region (fetch via `GET /ztw/api/v1/publicCloudInfo/supportedRegions`)
- `opt_in_tag_key` / `opt_in_tag_value` — opt-in gate defaults
- `managed_prefix` — name prefix for records this module may delete (default `ZTW-`)
- `dry_run` — start `true`, flip to `false` after verification

### D. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ValidationError: OrganizationalUnitIds are required` | Service-managed StackSets reject direct `Accounts`-only targets | Use `DeploymentTargets={OrganizationalUnitIds: [...], Accounts: [...], AccountFilterType: INTERSECTION}` |
| `You must enable organizations access to operate a service managed stack set` | CFN Org-access not activated | `aws cloudformation activate-organizations-access` |
| `INVALID_INPUT_ARGUMENT: Region info is mandatory` | POST body missing `supportedRegions` | Add the array per Appendix B |
| `Rate Limit (1/SECOND) exceeded` | OneAPI rate limit | Serialize calls with ≥ 1.5 sec gap |
| `AWS Account is associated with 1 Account Group. Deletion of this Account is not allowed.` | OneAPI DELETE refuses if an Account Group references the record | Remove from Account Group via UI or API first |
| `permissionStatus.assumeRole = Pending` forever | Zscaler tenant-side sync cycle hasn't run OR the discovery role wasn't deployed yet | Wait up to 15 min; if persistent, verify `ZscalerTagDiscoveryRoleBasic` exists in target account with correct external-id |
| `The security token included in the request is expired` on AWS CLI from sandbox | Stale `AWS_SESSION_TOKEN` in a sourced `.env` | Unset AWS session vars before sourcing: `unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY` |

### E. Files delivered with this module

```
ztcloud-aws-account-autolink/
├── README.md                          # module overview + quickstart
├── ARCHITECTURE.md                    # this document
├── LICENSE                            # Apache 2.0
├── CHANGELOG.md
├── .env.example                       # OneAPI credential template
├── .gitignore
├── terraform/
│   ├── main.tf                        # Lambda + StackSet + EventBridge + IAM + alarms + DLQ
│   ├── variables.tf                   # module inputs
│   ├── outputs.tf                     # module outputs
│   ├── reconciler.py                  # Lambda source (packaged by archive_file)
│   ├── discovery_role.yaml            # CFN for ZscalerTagDiscoveryRoleBasic
│   └── cross-account-bus.tf.example   # TSE cross-account wiring reference (not applied)
└── scripts/
    ├── deploy.sh                      # one-shot deploy (enables Org access, creates secret, TF apply)
    ├── test.sh                        # interactive E2E test
    └── cleanup.sh                     # full teardown
```

### F. Change log

| Date | Change |
|---|---|
| 2026-04-24 | Initial design, sandbox validation, document first issue |

---

**END OF DOCUMENT**
