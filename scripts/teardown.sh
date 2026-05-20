#!/usr/bin/env bash
# Clean teardown of the deployed stack.
#
# Force-empties the transcript bucket (terraform destroy can't delete a non-empty
# bucket unless force_destroy=true was applied), then runs terraform destroy and
# checks for orphaned ENIs.
#
# Usage:
#   bash scripts/teardown.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f terraform.tfvars ]; then
  echo "terraform.tfvars not found — refusing to destroy with no inputs"
  exit 1
fi

# Empty the transcript bucket first
BUCKET="$(terraform output -raw transcript_bucket 2>/dev/null || true)"
if [ -n "$BUCKET" ]; then
  echo "==> Emptying transcript bucket: $BUCKET"
  aws s3 rm "s3://$BUCKET" --recursive --only-show-errors || true
  # Versioned bucket: also delete all object versions + delete markers
  aws s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null \
    | jq -e '.Objects != null' >/dev/null 2>&1 \
    && aws s3api delete-objects --bucket "$BUCKET" \
         --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
                     --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" \
         >/dev/null || true
  aws s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null \
    | jq -e '.Objects != null' >/dev/null 2>&1 \
    && aws s3api delete-objects --bucket "$BUCKET" \
         --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
                     --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')" \
         >/dev/null || true
fi

echo "==> terraform destroy"
terraform destroy -auto-approve

# Sanity-check for orphaned ENIs (Fargate occasionally leaks these)
echo
echo "==> Checking for orphaned ENIs"
VPC_TAG="$(grep -E '^project_name' terraform.tfvars | awk -F= '{gsub(/[ "]/,"",$2); print $2}')"
ORPHANED="$(aws ec2 describe-network-interfaces \
  --filters Name=tag:Project,Values="$VPC_TAG" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)"

if [ -n "$ORPHANED" ] && [ "$ORPHANED" != "None" ]; then
  echo "Orphaned ENIs found — clean up manually:"
  echo "  $ORPHANED"
  exit 1
fi

echo "Teardown complete. No orphaned resources detected."
