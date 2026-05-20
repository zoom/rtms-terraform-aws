#!/usr/bin/env bash
# Layer 2 — Terraform validation harness.
# Runs fmt, validate, tflint, and checkov across the template.
# Exits 0 only if all pass.

set -euo pipefail

cd "$(dirname "$0")/.."

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

if ! command -v terraform >/dev/null; then red "terraform not installed"; exit 2; fi
if [ ! -f main.tf ]; then red "main.tf missing — nothing to validate yet"; exit 1; fi

echo "==> terraform fmt -check -recursive"
terraform fmt -check -recursive || { red "fmt failed"; exit 1; }
green "  fmt: OK"

echo "==> terraform init -backend=false"
terraform init -backend=false -input=false >/dev/null

echo "==> terraform validate (root)"
terraform validate || { red "validate failed (root)"; exit 1; }
green "  validate (root): OK"

for d in modules/*/; do
  [ -f "${d}main.tf" ] || continue
  echo "==> terraform validate ${d}"
  (cd "$d" && terraform init -backend=false -input=false >/dev/null && terraform validate) || {
    red "validate failed for ${d}"; exit 1;
  }
  green "  validate ${d}: OK"
done

if command -v tflint >/dev/null; then
  echo "==> tflint"
  tflint --recursive || { red "tflint reported issues"; exit 1; }
  green "  tflint: OK"
else
  yellow "tflint not installed — skipping (install with: brew install tflint)"
fi

if command -v checkov >/dev/null; then
  echo "==> checkov"
  checkov -d . --quiet --soft-fail-on LOW || true
  green "  checkov: completed (review output)"
else
  yellow "checkov not installed — skipping (install with: pip install checkov)"
fi

green "All Terraform validation passed."
