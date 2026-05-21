#!/usr/bin/env bash
# One-time bootstrap of the S3 bucket Terraform uses for remote state.
# Run before the first `terraform init`.
#
# State locking uses S3 native conditional writes (Terraform >= 1.10, the
# `use_lockfile = true` backend option) — no separate DynamoDB table needed.
#
# Usage:
#   AWS_REGION=us-east-1 PROJECT_NAME=rtms-demo bash scripts/bootstrap-state.sh

set -euo pipefail

# Disable AWS CLI v2 pager so JSON output goes straight to stdout instead of
# blocking on `less` for the user to press q.
export AWS_PAGER=""

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-rtms-demo}"
BUCKET="${PROJECT_NAME}-tfstate-$(aws sts get-caller-identity --query Account --output text)"

echo "Region:       $AWS_REGION"
echo "State bucket: $BUCKET"
echo

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "  state bucket already exists — skipping create"
else
  echo "  creating state bucket"
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

echo
echo "Bootstrap complete. Initialize Terraform with:"
echo
echo "  terraform init \\"
echo "    -backend-config=\"bucket=$BUCKET\" \\"
echo "    -backend-config=\"key=$PROJECT_NAME/terraform.tfstate\" \\"
echo "    -backend-config=\"region=$AWS_REGION\" \\"
echo "    -backend-config=\"use_lockfile=true\" \\"
echo "    -backend-config=\"encrypt=true\""
