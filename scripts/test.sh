#!/usr/bin/env bash
# End-to-end test: onboard + offboard a single target account.
# Usage: ./scripts/test.sh <TARGET_ACCOUNT_ID>
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <TARGET_ACCOUNT_ID>"
  echo "  TARGET_ACCOUNT_ID — a workload account in the same AWS Organization to tag and onboard."
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
TARGET_ACCOUNT="$1"
REGION="${AWS_REGION:-us-east-1}"
FN="${LAMBDA_NAME:-ztw-reconciler}"
TAG_KEY="${TAG_KEY:-zscaler-managed}"
TAG_VALUE="${TAG_VALUE:-true}"

ztw_token() {
  local vanity client_id client_secret
  vanity=$(grep -E '^export ZS_VANITY_DOMAIN=' "$ENV_FILE" | sed 's/^export ZS_VANITY_DOMAIN=//; s/^"//; s/"$//')
  client_id=$(grep -E '^export ZS_CLIENT_ID=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_ID=//; s/^"//; s/"$//')
  client_secret=$(grep -E '^export ZS_CLIENT_SECRET=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_SECRET=//; s/^"//; s/"$//')
  curl -s -X POST "https://${vanity}/oauth2/v1/token" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "client_secret=${client_secret}" \
    --data-urlencode "audience=https://api.zscaler.com" | jq -r '.access_token'
}

ztw_list() {
  local t="$1"
  curl -s "https://api.zsapi.net/ztw/api/v1/publicCloudInfo" -H "Authorization: Bearer $t" \
    | jq '[.[] | {id, name, awsAccountId: .accountDetails.awsAccountId, assumeRole: .permissionStatus.status.assumeRole}]'
}

invoke_async() {
  local out payload
  out=$(mktemp); payload="$1"
  aws lambda invoke --function-name "$FN" --region "$REGION" --invocation-type Event \
    --cli-binary-format raw-in-base64-out --payload "$payload" "$out" | jq .
  rm -f "$out"
}

wait_for_result() {
  local marker="$1" i log
  for i in $(seq 1 36); do
    sleep 10
    log=$(aws logs tail /aws/lambda/$FN --region $REGION --since 5m 2>/dev/null)
    if echo "$log" | grep "$marker" | grep -q "result:"; then
      echo "$log" | grep -A 100 "$marker" | tail -30
      return 0
    fi
    echo "   [+$((i*10))s] waiting for $marker result..."
  done
  echo "   TIMED OUT after 6 min. Check logs manually."
  return 1
}

flip_dry_run() {
  local val="$1" current
  current=$(aws lambda get-function-configuration --function-name "$FN" --region "$REGION" --output json | jq -r '.Environment.Variables | to_entries | map("\(.key)=\(.value)") | join(",")')
  # Update DRY_RUN key, keeping other env vars
  local new_env
  new_env=$(aws lambda get-function-configuration --function-name "$FN" --region "$REGION" --output json \
    | jq --arg val "$val" '.Environment.Variables.DRY_RUN = $val | .Environment.Variables | to_entries | map("\(.key)=\(.value)") | join(",")' -r)
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --environment "Variables={$new_env}" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  echo "   DRY_RUN=$val"
}

step() { echo; echo "================================================================"; echo "  $*"; echo "================================================================"; }

# --- Test flow ---
TOKEN=$(ztw_token)

step "Baseline: Zscaler tenant AWS accounts"
ztw_list "$TOKEN"

step "1. Tag target account $TARGET_ACCOUNT with $TAG_KEY=$TAG_VALUE"
aws organizations tag-resource --resource-id "$TARGET_ACCOUNT" --tags Key="$TAG_KEY",Value="$TAG_VALUE"
aws organizations list-tags-for-resource --resource-id "$TARGET_ACCOUNT" --output json | jq '.Tags'

step "2. Dry-run invoke (verifies diff logic without side effects)"
flip_dry_run "true"
invoke_async '{"detail-type":"manual-test-dry-run"}'
wait_for_result "manual-test-dry-run" || true

step "3. Live onboard (DRY_RUN=false)"
flip_dry_run "false"
invoke_async '{"detail-type":"manual-test-onboard"}'
wait_for_result "manual-test-onboard"

step "4. Verify: StackSet instance deployed to target"
aws cloudformation list-stack-instances --stack-set-name ztw-discovery-role --region "$REGION" --output json \
  | jq '.Summaries[] | {Account, Region, Status, DetailedStatus: .StackInstanceStatus.DetailedStatus}'

step "5. Verify: account onboarded in Zscaler tenant"
TOKEN=$(ztw_token)
ztw_list "$TOKEN"

step "6. Pause before offboard test"
read -r -p "Press enter to proceed with offboard (Ctrl-C to stop and inspect)..."

step "7. Untag + invoke"
aws organizations untag-resource --resource-id "$TARGET_ACCOUNT" --tag-keys "$TAG_KEY"
invoke_async '{"detail-type":"manual-test-offboard"}'
wait_for_result "manual-test-offboard"

step "8. Verify: removed from Zscaler tenant"
TOKEN=$(ztw_token)
ztw_list "$TOKEN"

step "9. Flip DRY_RUN=true (safe idle default)"
flip_dry_run "true"

echo
echo "Test complete."
