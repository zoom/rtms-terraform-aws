#!/usr/bin/env bash
#
# publish-to-ecr-public.sh — build the worker image and push it to AWS ECR Public.
#
# Customers can then pull the image anonymously via `terraform apply` without
# needing Docker installed locally or ECR auth in their own AWS account.
#
# Usage:
#   ECR_PUBLIC_ALIAS=maxmansfield TAG=1.1.0 bash scripts/publish-to-ecr-public.sh
#
# Or for a one-off without env vars:
#   bash scripts/publish-to-ecr-public.sh maxmansfield 1.1.0
#
# Prerequisites:
#   - You've set up an ECR Public registry alias in the AWS Console
#     (https://us-east-1.console.aws.amazon.com/ecr/public/registries)
#   - You're authenticated as a user with ECR Public write access
#   - Docker Desktop running (script builds linux/amd64 for Fargate)

set -euo pipefail

# Disable AWS CLI v2 pager so JSON output goes straight to stdout instead of
# blocking on `less` for the user to press q.
export AWS_PAGER=""

cd "$(dirname "$0")/.."

# ── inputs ───────────────────────────────────────────────────────────────────
ECR_PUBLIC_ALIAS="${ECR_PUBLIC_ALIAS:-${1:-}}"
TAG="${TAG:-${2:-1.1.0}}"
REPO_NAME="${REPO_NAME:-rtms-worker}"

if [ -z "$ECR_PUBLIC_ALIAS" ]; then
  echo "ERROR: ECR_PUBLIC_ALIAS must be set." >&2
  echo "Usage: ECR_PUBLIC_ALIAS=<your-alias> TAG=1.1.0 bash $0" >&2
  exit 1
fi

# ECR Public is always us-east-1 (it's a global registry, but the API lives there)
export AWS_REGION=us-east-1

IMAGE_URI="public.ecr.aws/${ECR_PUBLIC_ALIAS}/${REPO_NAME}:${TAG}"
LATEST_URI="public.ecr.aws/${ECR_PUBLIC_ALIAS}/${REPO_NAME}:latest"

# ── helpers ──────────────────────────────────────────────────────────────────
hr()    { printf '%s\n' "─────────────────────────────────────────────────────"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
info()  { printf '\033[2m%s\033[0m\n' "$*"; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. verify alias is configured ────────────────────────────────────────────
echo "==> Verifying ECR Public alias '$ECR_PUBLIC_ALIAS' is registered to this account"
ALIASES=$(aws ecr-public describe-registries --region us-east-1 \
  --query 'registries[0].aliases[].name' --output text 2>/dev/null || true)

if ! echo "$ALIASES" | tr '\t' '\n' | grep -qx "$ECR_PUBLIC_ALIAS"; then
  fail "Alias '$ECR_PUBLIC_ALIAS' is not registered to your AWS account. Existing aliases: ${ALIASES:-(none)}.
Set one up in the console: https://us-east-1.console.aws.amazon.com/ecr/public/registries"
fi
ok "Alias '$ECR_PUBLIC_ALIAS' is registered"

# ── 2. ensure the repository exists ─────────────────────────────────────────
echo "==> Ensuring repository '$REPO_NAME' exists in ECR Public"
if aws ecr-public describe-repositories --region us-east-1 \
     --repository-names "$REPO_NAME" >/dev/null 2>&1; then
  ok "Repository exists"
else
  aws ecr-public create-repository \
    --repository-name "$REPO_NAME" \
    --region us-east-1 \
    --catalog-data '{
      "description": "Zoom Real-Time Media Streaming (RTMS) consumer for cloud deploys. Built from https://github.com/zoom/rtms.",
      "architectures": ["x86-64"],
      "operatingSystems": ["Linux"]
    }' >/dev/null
  ok "Repository created"
fi

# ── 3. authenticate Docker to ECR Public ────────────────────────────────────
echo "==> Logging Docker into ECR Public"
aws ecr-public get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin public.ecr.aws

# ── 4. build for linux/amd64 (Fargate target) ───────────────────────────────
echo "==> Building image (linux/amd64)"
docker build \
  --platform linux/amd64 \
  -t "$IMAGE_URI" \
  -t "$LATEST_URI" \
  ./worker

# ── 5. push both tags ────────────────────────────────────────────────────────
echo "==> Pushing $IMAGE_URI"
docker push "$IMAGE_URI"
echo "==> Pushing $LATEST_URI"
docker push "$LATEST_URI"

# ── 6. summary ───────────────────────────────────────────────────────────────
hr
ok "Published to ECR Public"
echo
echo "  Versioned: $IMAGE_URI"
echo "  Latest:    $LATEST_URI"
echo
echo "Customers can now pull anonymously. Update terraform.tfvars.example and"
echo "deploy.sh defaults to:"
echo
echo "  worker_image = \"$IMAGE_URI\""
echo
echo "Or have customers use :latest for auto-updates:"
echo
echo "  worker_image = \"$LATEST_URI\""
echo
hr
