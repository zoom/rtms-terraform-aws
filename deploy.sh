#!/usr/bin/env bash
#
# deploy.sh — guided one-command setup for the RTMS-on-AWS Terraform template.
#
# Run from the repo root:
#     ./deploy.sh
#
# What it does (in order, each step idempotent):
#   1. Verifies prerequisites (aws, terraform, jq)
#   2. Prompts for missing inputs; preserves existing terraform.tfvars on re-runs
#   3. Creates 3 Secrets Manager entries for Zoom credentials (skips ones that exist)
#   4. Bootstraps Terraform state backend (skips if bucket exists)
#   5. Writes terraform.tfvars (or updates the version pin if image was rebuilt)
#   6. terraform init (reconfigures if backend changed)
#   7. terraform plan (so you see what's about to happen)
#   8. terraform apply (with explicit confirmation)
#   9. Prints the webhook URL and next steps
#
# Re-running picks up where it left off — safe to interrupt and resume.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

# ── colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'
else
  C_RESET=; C_DIM=; C_BOLD=; C_OK=; C_WARN=; C_ERR=; C_INFO=
fi

step()  { printf "\n${C_BOLD}${C_INFO}==>${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$*"; }
ok()    { printf "${C_OK}✓${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_WARN}!${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_ERR}✗${C_RESET} %s\n" "$*" >&2; exit 1; }
info()  { printf "${C_DIM}%s${C_RESET}\n" "$*"; }
hr()    { printf "${C_DIM}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────"; }

# ── prompt helpers ───────────────────────────────────────────────────────────
prompt() {
  # prompt VARNAME PROMPT_TEXT [DEFAULT]
  local var="$1" msg="$2" default="${3:-}"
  local cur="${!var:-}"

  if [ -n "$cur" ]; then
    printf "${C_DIM}%s [%s]:${C_RESET} " "$msg" "$cur"
  elif [ -n "$default" ]; then
    printf "%s [${C_DIM}%s${C_RESET}]: " "$msg" "$default"
  else
    printf "%s: " "$msg"
  fi

  local input
  IFS= read -r input </dev/tty
  if [ -z "$input" ]; then
    input="${cur:-$default}"
  fi
  printf -v "$var" '%s' "$input"
}

prompt_secret() {
  # like prompt but hides input
  local var="$1" msg="$2"
  printf "%s: " "$msg"
  local input
  IFS= read -rs input </dev/tty
  printf "\n"
  printf -v "$var" '%s' "$input"
}

prompt_choice() {
  # prompt_choice VARNAME PROMPT_TEXT DEFAULT_INDEX "option1" "option2" ...
  local var="$1" msg="$2" default="$3"; shift 3
  local options=("$@")
  printf "%s\n" "$msg"
  for i in "${!options[@]}"; do
    printf "  ${C_BOLD}%d${C_RESET}) %s\n" "$((i+1))" "${options[$i]}"
  done
  printf "Choice [${C_DIM}%s${C_RESET}]: " "$default"
  local input
  IFS= read -r input </dev/tty
  input="${input:-$default}"
  if ! [[ "$input" =~ ^[1-9][0-9]*$ ]] || [ "$input" -gt "${#options[@]}" ]; then
    fail "Invalid choice: $input"
  fi
  printf -v "$var" '%s' "${options[$((input-1))]}"
}

confirm() {
  # confirm "message" — returns 0 if yes
  local msg="$1"
  printf "${C_WARN}?${C_RESET} %s [y/N]: " "$msg"
  local input
  IFS= read -r input </dev/tty
  [[ "$input" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ── 1. prereqs ───────────────────────────────────────────────────────────────
check_prereqs() {
  step "Checking prerequisites"
  local missing=()
  for cmd in aws terraform jq; do
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "$cmd $(${cmd} --version 2>&1 | head -1)"
    else
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    warn "Missing required tools: ${missing[*]}"
    cat <<EOF
Install on macOS:
  brew install ${missing[*]}
Or follow the per-tool instructions in README.md.
EOF
    exit 1
  fi

  # Confirm AWS creds work
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    fail "AWS CLI is not authenticated. Run 'aws configure' or 'aws sso login' first."
  fi
  local who
  who=$(aws sts get-caller-identity --query 'Arn' --output text)
  ok "AWS authenticated as: $who"
}

# ── 2. load existing tfvars (if any) ─────────────────────────────────────────
# Sourcing tfvars directly would interpret it as bash — won't work.
# Parse just the keys we need with grep.
TFVARS=terraform.tfvars
read_existing() {
  step "Reading existing terraform.tfvars (if present)"
  if [ ! -f "$TFVARS" ]; then
    info "No existing terraform.tfvars — starting fresh."
    return
  fi

  ok "Found existing $TFVARS — values used as defaults; press Enter to keep, or type new"

  # Extract a value from terraform.tfvars given a key name.
  tf_get() {
    grep -E "^\s*${1}\s*=" "$TFVARS" | head -1 \
      | sed -E 's/^[^=]*=\s*//; s/^"(.*)"$/\1/; s/[[:space:]]*$//'
  }

  AWS_REGION="${AWS_REGION:-$(tf_get aws_region)}"
  PROJECT_NAME="${PROJECT_NAME:-$(tf_get project_name)}"
  WEBHOOK_DOMAIN="${WEBHOOK_DOMAIN:-$(tf_get webhook_domain)}"
  DNS_MODE="${DNS_MODE:-$(tf_get dns_mode)}"
  ROUTE53_ZONE_ID="${ROUTE53_ZONE_ID:-$(tf_get route53_zone_id)}"
  ACM_CERT_ARN="${ACM_CERT_ARN:-$(tf_get acm_certificate_arn)}"
  WORKER_IMAGE="${WORKER_IMAGE:-$(tf_get worker_image)}"
  BUDGET_EMAIL="${BUDGET_EMAIL:-$(tf_get budget_alert_email)}"

  ZM_CLIENT_ARN="${ZM_CLIENT_ARN:-$(tf_get zm_rtms_client_secret_arn)}"
  ZM_SECRET_ARN="${ZM_SECRET_ARN:-$(tf_get zm_rtms_secret_secret_arn)}"
  ZM_WEBHOOK_ARN="${ZM_WEBHOOK_ARN:-$(tf_get zm_rtms_webhook_secret_secret_arn)}"
}

# ── 3. prompt for inputs ─────────────────────────────────────────────────────
prompt_inputs() {
  step "Configuration"
  prompt AWS_REGION "AWS region" "us-east-1"
  prompt PROJECT_NAME "Project name (resource prefix)" "rtms-demo"
  prompt WEBHOOK_DOMAIN "Webhook subdomain (e.g. rtms.example.com)"

  if [ -z "$WEBHOOK_DOMAIN" ]; then
    fail "webhook_domain is required."
  fi

  step "DNS"
  if [ -n "$DNS_MODE" ]; then
    info "Existing dns_mode = $DNS_MODE — keeping (re-run with DNS_MODE=route53 or DNS_MODE=external to change)"
  else
    prompt_choice DNS_MODE "How is your domain's DNS hosted?" "1" \
      "route53 — magic path (Terraform creates the cert + records for you)" \
      "external — Squarespace / Cloudflare / GoDaddy / etc. (you handle DNS)"
    # Trim trailing description text from the option label
    DNS_MODE="${DNS_MODE%% *}"
  fi

  if [ "$DNS_MODE" = "route53" ]; then
    if [ -z "$ROUTE53_ZONE_ID" ] || [ "$ROUTE53_ZONE_ID" = "null" ]; then
      info "Find your zone ID:"
      info "  aws route53 list-hosted-zones --query \"HostedZones[?Name=='\${ZONE}.'].Id\" --output text"
    fi
    prompt ROUTE53_ZONE_ID "Route 53 hosted zone ID (e.g. Z01234567ABCDEFGH)"
    if [ -z "$ROUTE53_ZONE_ID" ]; then
      fail "route53_zone_id is required for dns_mode=route53."
    fi
    # Strip /hostedzone/ prefix if user pasted full path
    ROUTE53_ZONE_ID="${ROUTE53_ZONE_ID##*/}"
    ACM_CERT_ARN=""
  else
    if [ -z "$ACM_CERT_ARN" ] || [ "$ACM_CERT_ARN" = "null" ]; then
      info "You'll need a pre-issued ACM cert for $WEBHOOK_DOMAIN in region $AWS_REGION."
      info "See README → 'External DNS path' for how to issue + validate one."
    fi
    prompt ACM_CERT_ARN "ACM certificate ARN"
    if [ -z "$ACM_CERT_ARN" ]; then
      fail "acm_certificate_arn is required for dns_mode=external."
    fi
    ROUTE53_ZONE_ID=""
  fi

  step "Zoom Marketplace RTMS app credentials"
  if [ -n "$ZM_CLIENT_ARN" ] && [ -n "$ZM_SECRET_ARN" ] && [ -n "$ZM_WEBHOOK_ARN" ]; then
    info "Found existing Secrets Manager ARNs in tfvars — re-using."
    info "  (delete those entries from terraform.tfvars and re-run to re-prompt)"
    SKIP_SECRETS=1
  else
    info "Paste these from your Zoom Marketplace RTMS app:"
    prompt_secret ZM_CLIENT_VAL "  ZM_RTMS_CLIENT"
    prompt_secret ZM_SECRET_VAL "  ZM_RTMS_SECRET"
    prompt_secret ZM_WEBHOOK_VAL "  ZM_RTMS_WEBHOOK_SECRET"
    SKIP_SECRETS=0
  fi

  step "Misc"
  prompt BUDGET_EMAIL "Budget alert email"
  prompt WORKER_IMAGE "Worker image URI (leave default to use public image)" \
    "public.ecr.aws/t3b9e0y5/rtms-worker:1.1.0"
}

# ── 4. secrets manager (idempotent) ──────────────────────────────────────────
ensure_secrets() {
  step "Secrets Manager"
  if [ "$SKIP_SECRETS" = "1" ]; then
    ok "Using existing secret ARNs from tfvars"
    return
  fi

  create_or_get_secret() {
    local name="$1" value="$2"
    local arn
    arn=$(aws secretsmanager describe-secret --secret-id "$name" --region "$AWS_REGION" \
      --query 'ARN' --output text 2>/dev/null || true)
    if [ -n "$arn" ] && [ "$arn" != "None" ]; then
      ok "$name exists → $arn"
      printf '%s' "$arn"
      return
    fi
    arn=$(aws secretsmanager create-secret --name "$name" --secret-string "$value" \
      --region "$AWS_REGION" --query 'ARN' --output text)
    ok "$name created → $arn"
    printf '%s' "$arn"
  }

  ZM_CLIENT_ARN=$(create_or_get_secret "${PROJECT_NAME}/zm-rtms-client" "$ZM_CLIENT_VAL")
  ZM_SECRET_ARN=$(create_or_get_secret "${PROJECT_NAME}/zm-rtms-secret" "$ZM_SECRET_VAL")
  ZM_WEBHOOK_ARN=$(create_or_get_secret "${PROJECT_NAME}/zm-rtms-webhook-secret" "$ZM_WEBHOOK_VAL")

  # Scrub from memory
  unset ZM_CLIENT_VAL ZM_SECRET_VAL ZM_WEBHOOK_VAL
}

# ── 5. bootstrap state (idempotent) ──────────────────────────────────────────
ensure_state_backend() {
  step "Terraform state backend (S3)"
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text)
  STATE_BUCKET="${PROJECT_NAME}-tfstate-${acct}"

  if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    ok "State bucket exists: $STATE_BUCKET"
  else
    AWS_REGION="$AWS_REGION" PROJECT_NAME="$PROJECT_NAME" \
      bash scripts/bootstrap-state.sh
    ok "Bootstrapped state bucket: $STATE_BUCKET"
  fi
}

# ── 6. write tfvars ──────────────────────────────────────────────────────────
write_tfvars() {
  step "Writing terraform.tfvars"

  local route53_line=""
  local acm_line=""
  if [ "$DNS_MODE" = "route53" ]; then
    route53_line="route53_zone_id     = \"$ROUTE53_ZONE_ID\""
    acm_line=""
  else
    route53_line=""
    acm_line="acm_certificate_arn = \"$ACM_CERT_ARN\""
  fi

  # Back up existing tfvars if present
  if [ -f "$TFVARS" ]; then
    cp "$TFVARS" "${TFVARS}.bak.$(date +%s)"
  fi

  cat > "$TFVARS" <<EOF
# Generated by deploy.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Hand-edits OK; deploy.sh
# will preserve existing values on re-runs (it only fills gaps).

# --- Identity / region ---
aws_region   = "$AWS_REGION"
project_name = "$PROJECT_NAME"
environment  = "demo"

# --- Pre-created Secrets Manager ARNs ---
zm_rtms_client_secret_arn         = "$ZM_CLIENT_ARN"
zm_rtms_secret_secret_arn         = "$ZM_SECRET_ARN"
zm_rtms_webhook_secret_secret_arn = "$ZM_WEBHOOK_ARN"

# --- TLS / DNS ---
dns_mode       = "$DNS_MODE"
webhook_domain = "$WEBHOOK_DOMAIN"
$route53_line
$acm_line

# --- Worker container image ---
worker_image = "$WORKER_IMAGE"

# --- Cost guardrail ---
monthly_budget_usd = 50
budget_alert_email = "$BUDGET_EMAIL"

# --- Tags ---
tags = {
  Project     = "$PROJECT_NAME"
  Environment = "demo"
}
EOF
  ok "Wrote $TFVARS"
}

# ── 7-9. init + plan + apply ─────────────────────────────────────────────────
run_terraform() {
  step "terraform init"
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text)

  terraform init -reconfigure \
    -backend-config="bucket=${PROJECT_NAME}-tfstate-${acct}" \
    -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true"

  step "terraform plan"
  terraform plan -out=/tmp/rtms-tfplan
  hr

  if ! confirm "Apply this plan?"; then
    info "Aborted. Re-run ./deploy.sh when ready."
    exit 0
  fi

  step "terraform apply"
  terraform apply /tmp/rtms-tfplan
}

# ── 10. summarize ────────────────────────────────────────────────────────────
finalize() {
  step "Done"
  local webhook_url alb_dns transcript_bucket log_group
  webhook_url=$(terraform output -raw webhook_url)
  alb_dns=$(terraform output -raw alb_dns_name)
  transcript_bucket=$(terraform output -raw transcript_bucket)
  log_group=$(terraform output -raw log_group_name)

  echo
  ok "Webhook URL:       $webhook_url"
  ok "ALB DNS:           $alb_dns"
  ok "Transcript bucket: s3://$transcript_bucket/"
  ok "Worker logs:       $log_group"
  echo

  if [ "$DNS_MODE" = "external" ]; then
    warn "External DNS mode — you still need to point your DNS at the ALB:"
    info "  At your DNS provider, create a CNAME (or ALIAS):"
    info "    name:  ${WEBHOOK_DOMAIN%%.*}"
    info "    value: $alb_dns"
  fi

  echo
  cat <<EOF
${C_BOLD}Next steps:${C_RESET}
  1. Paste the webhook URL into your Zoom Marketplace RTMS app's
     Event Subscription endpoint:
       $webhook_url
  2. Click 'Validate' in the Marketplace UI.
  3. Start a Zoom meeting with RTMS enabled.
  4. Watch logs:
       aws logs tail $log_group --follow --region $AWS_REGION
  5. Watch transcripts:
       aws s3 ls s3://$transcript_bucket/transcripts/ --recursive --region $AWS_REGION

${C_BOLD}Teardown when done:${C_RESET}
  ./scripts/teardown.sh

${C_DIM}Idle cost is around \$20/mo (ALB-dominant). Tear down between sessions.${C_RESET}
EOF
}

# ── main ─────────────────────────────────────────────────────────────────────
banner() {
  cat <<EOF
${C_BOLD}
╭───────────────────────────────────────────────╮
│  RTMS on AWS — guided setup                   │
│  Deploys Zoom RTMS to ECS Fargate in ~10 min  │
╰───────────────────────────────────────────────╯${C_RESET}
EOF
}

main() {
  banner
  check_prereqs
  read_existing
  prompt_inputs
  ensure_secrets
  ensure_state_backend
  write_tfvars
  run_terraform
  finalize
}

main "$@"
