#!/usr/bin/env bash
# Deploy ztcloud-aws-account-autolink.
#
# Prereqs:
#   - AWS CLI authenticated in the target account (Audit in TSE deployments, Management in single-account sandboxes)
#   - .env populated (see .env.example) with ZS_VANITY_DOMAIN, ZS_CLIENT_ID, ZS_CLIENT_SECRET
#   - Terraform 1.5+
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
SECRET_ID="${SECRET_ID:-zscaler/oneapi-creds}"
REGION="${AWS_REGION:-us-east-1}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example to .env and populate."
  exit 1
fi

echo "==> Loading Zscaler OneAPI creds from $ENV_FILE"
# Extract only ZS_* vars — avoid clobbering AWS creds already in the shell
ZS_VANITY_DOMAIN=$(grep -E '^export ZS_VANITY_DOMAIN=' "$ENV_FILE" | sed 's/^export ZS_VANITY_DOMAIN=//; s/^"//; s/"$//')
ZS_CLIENT_ID=$(grep -E '^export ZS_CLIENT_ID=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_ID=//; s/^"//; s/"$//')
ZS_CLIENT_SECRET=$(grep -E '^export ZS_CLIENT_SECRET=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_SECRET=//; s/^"//; s/"$//')

if [ -z "$ZS_VANITY_DOMAIN" ] || [ -z "$ZS_CLIENT_ID" ] || [ -z "$ZS_CLIENT_SECRET" ]; then
  echo "ERROR: one or more of ZS_VANITY_DOMAIN, ZS_CLIENT_ID, ZS_CLIENT_SECRET is empty in $ENV_FILE"
  exit 1
fi

echo "==> Verifying AWS identity"
aws sts get-caller-identity --output text --query Arn

echo "==> Enabling AWS Organizations trusted access for service-managed StackSets (idempotent)"
aws organizations enable-aws-service-access \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com 2>/dev/null || echo "   already enabled"

echo "==> Activating CloudFormation organizations-access (idempotent)"
aws cloudformation activate-organizations-access --region "$REGION" 2>/dev/null || echo "   already activated"
aws cloudformation describe-organizations-access --region "$REGION" --output text --query Status

echo "==> Creating / updating Zscaler OneAPI secret ($SECRET_ID)"
SEC_JSON=$(jq -n --arg v "$ZS_VANITY_DOMAIN" --arg i "$ZS_CLIENT_ID" --arg s "$ZS_CLIENT_SECRET" \
  '{vanity:$v, client_id:$i, client_secret:$s}')
if aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$SEC_JSON" --region "$REGION" >/dev/null
  echo "   secret updated"
else
  aws secretsmanager create-secret --name "$SECRET_ID" --secret-string "$SEC_JSON" --region "$REGION" >/dev/null
  echo "   secret created"
fi

echo "==> terraform init + apply"
cd "$ROOT/terraform"
terraform init -upgrade -input=false
terraform apply -auto-approve -input=false -var "region=$REGION" -var "zs_secret_id=$SECRET_ID"

echo
echo "Deploy complete. Outputs:"
terraform output
echo
echo "Lambda starts in DRY_RUN=true mode. Verify with:"
echo "  aws lambda invoke --function-name ztw-reconciler --payload '{}' out.json && cat out.json"
echo "Flip to live with:"
echo "  terraform apply -var dry_run=false"
