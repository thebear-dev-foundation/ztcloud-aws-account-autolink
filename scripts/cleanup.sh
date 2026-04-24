#!/usr/bin/env bash
# Full teardown: remove all Zscaler records created by this module,
# delete StackSet instances, destroy Terraform-managed resources.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
REGION="${AWS_REGION:-us-east-1}"
STACKSET="${STACKSET_NAME:-ztw-discovery-role}"
MANAGED_PREFIX="${MANAGED_PREFIX:-ZTW-}"
TAG_KEY="${TAG_KEY:-zscaler-managed}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found."
  exit 1
fi

echo "==> Loading OneAPI creds"
ZS_VANITY_DOMAIN=$(grep -E '^export ZS_VANITY_DOMAIN=' "$ENV_FILE" | sed 's/^export ZS_VANITY_DOMAIN=//; s/^"//; s/"$//')
ZS_CLIENT_ID=$(grep -E '^export ZS_CLIENT_ID=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_ID=//; s/^"//; s/"$//')
ZS_CLIENT_SECRET=$(grep -E '^export ZS_CLIENT_SECRET=' "$ENV_FILE" | sed 's/^export ZS_CLIENT_SECRET=//; s/^"//; s/"$//')

echo "==> Removing any Zscaler tenant records with prefix '$MANAGED_PREFIX'"
TOKEN=$(curl -s -X POST "https://${ZS_VANITY_DOMAIN}/oauth2/v1/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${ZS_CLIENT_ID}" \
  --data-urlencode "client_secret=${ZS_CLIENT_SECRET}" \
  --data-urlencode "audience=https://api.zscaler.com" | jq -r '.access_token')

curl -s "https://api.zsapi.net/ztw/api/v1/publicCloudInfo" -H "Authorization: Bearer $TOKEN" \
  | jq --arg p "$MANAGED_PREFIX" -r '.[] | select(.name | startswith($p)) | "\(.id) \(.name)"' | while read -r id name; do
  [ -z "$id" ] && continue
  echo "   DELETE $id ($name)"
  curl -s -X DELETE "https://api.zsapi.net/ztw/api/v1/publicCloudInfo/$id" -H "Authorization: Bearer $TOKEN"; echo
  sleep 2
done

echo "==> Untagging any accounts still tagged $TAG_KEY=true"
for aid in $(aws organizations list-accounts --output json | jq -r '.Accounts[].Id'); do
  if aws organizations list-tags-for-resource --resource-id "$aid" --output json 2>/dev/null \
     | jq -e --arg k "$TAG_KEY" '.Tags | any(.Key == $k)' >/dev/null; then
    echo "   untag $aid"
    aws organizations untag-resource --resource-id "$aid" --tag-keys "$TAG_KEY"
  fi
done

echo "==> Deleting StackSet instances"
INSTANCES=$(aws cloudformation list-stack-instances --stack-set-name "$STACKSET" --region "$REGION" --output json 2>/dev/null | jq -r '.Summaries[].Account' || true)
if [ -n "$INSTANCES" ]; then
  ACCTS=$(echo "$INSTANCES" | paste -sd, -)
  aws cloudformation delete-stack-instances --stack-set-name "$STACKSET" \
    --deployment-targets Accounts="$ACCTS" --regions "$REGION" --no-retain-stacks \
    --operation-preferences MaxConcurrentCount=1,FailureToleranceCount=0 \
    --region "$REGION" >/dev/null || true
  echo "   waiting 60s for instance deletion..."
  sleep 60
fi

echo "==> terraform destroy"
cd "$ROOT/terraform"
terraform destroy -auto-approve -input=false

echo
echo "Cleanup complete."
