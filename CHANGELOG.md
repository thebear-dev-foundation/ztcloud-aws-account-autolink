# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-04-24

### Added
- Initial reference implementation.
- Reconciler Lambda with diff-based Org ⇄ Zscaler convergence.
- Service-managed CloudFormation StackSet for `ZscalerTagDiscoveryRoleBasic`.
- EventBridge triggers: LZA pipeline stage-completion hook (`aws.codepipeline`) and daily safety-net schedule.
- Opt-in tag gate (`zscaler-managed=true`) and managed-prefix name guard.
- Dry-run default.
- Architecture, security, and risk-review document (`ARCHITECTURE.md`).
- Cross-account bus reference template (`cross-account-bus.tf.example`).
- End-to-end test script against a single target account.

### Not yet implemented (see ARCHITECTURE.md §12)
- Dead-letter queue wired to the Lambda.
- Customer-managed KMS key for the OneAPI secret.
- VPC-attached Lambda + VPC endpoints.
- Secrets Manager rotation Lambda.
- Step-Function approval gate for initial onboardings.
- EMF custom metrics.
- X-Ray tracing.
