#!/usr/bin/env bash
# Build the worker Docker image and push it to a private ECR repo in your
# AWS account. Creates the repo if it doesn't exist. Prints the image URI
# you paste into terraform.tfvars as `worker_image`.
#
# Usage:
#   AWS_REGION=us-east-1 PROJECT_NAME=rtms-demo TAG=0.1.0 bash scripts/build-and-push-worker.sh

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-rtms-demo}"
TAG="${TAG:-$(date +%Y%m%d-%H%M%S)}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REPO_NAME="${PROJECT_NAME}-worker"
REPO_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}"
IMAGE_URI="${REPO_URI}:${TAG}"

cd "$(dirname "$0")/.."

echo "==> Ensuring ECR repository exists: ${REPO_NAME}"
if ! aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws ecr create-repository \
    --repository-name "$REPO_NAME" \
    --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE >/dev/null
  echo "    created"
else
  echo "    already exists"
fi

echo "==> Logging Docker into ECR"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Building image (linux/amd64 for Fargate)"
docker build \
  --platform linux/amd64 \
  -t "rtms-worker:${TAG}" \
  -t "${IMAGE_URI}" \
  ./worker

echo "==> Pushing to ${IMAGE_URI}"
docker push "${IMAGE_URI}"

echo
echo "==============================================================="
echo "  Image pushed. Paste this into terraform.tfvars:"
echo
echo "    worker_image = \"${IMAGE_URI}\""
echo "==============================================================="
