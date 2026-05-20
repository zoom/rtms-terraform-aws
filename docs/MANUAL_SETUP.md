# Manual Setup — Step-by-Step Walkthrough

Most users should run `./deploy.sh` (see the [README Quick Start](../README.md#quick-start)). This document walks through each step the script does, in case you want to:

- Integrate the steps into your own pipeline
- Audit what gets created before running anything
- Learn what's happening under the hood
- Recover from a partial deploy

Run each block from the repository root. End-to-end time: ~30 minutes, most of it waiting on ACM cert validation and `terraform apply`.

## Deployment Walkthrough

End-to-end time: ~30 minutes, most of it waiting on ACM cert validation and `terraform apply`.

### Step 1 — Install the AWS CLI

```bash
# Homebrew (recommended on macOS)
brew install awscli

# Verify
aws --version
# expect: aws-cli/2.x.x ...
```

If you don't have Homebrew, use the [official PKG installer](https://awscli.amazonaws.com/AWSCLIV2.pkg) from AWS.

### Step 2 — Configure AWS credentials

Use **IAM Identity Center** (formerly AWS SSO) for CLI access. It issues short-lived credentials that expire automatically — no long-lived access keys to rotate or leak. AWS explicitly recommends this over long-lived IAM user keys.

One-time setup in the AWS Console:

1. **IAM Identity Center** → **Enable** (home region = `us-east-1`)
2. **Users** → Add a user with your email and a permission set scoped to the privileges this template needs (see [spec.md → Credential Handling](spec.md) for the minimum policy). Confirm the activation email.
3. **AWS accounts** → select this account → **Assign users or groups** → pick your user and the permission set.

Configure the CLI:

```bash
aws configure sso
# SSO session name:   rtms-deploy
# SSO start URL:      <copy from IAM Identity Center settings page>
# SSO region:         us-east-1
# CLI default Region: us-east-1
# CLI default output: json
# Profile name:       rtms-deploy

aws sso login --profile rtms-deploy
export AWS_PROFILE=rtms-deploy    # add to ~/.zshrc / ~/.bashrc if you want it persistent

aws sts get-caller-identity
# expect: an Arn ending in `assumed-role/<permission-set-name>/...`
```

> **IAM user with long-lived access keys** is also possible (Console → IAM → Users → Create user → access key → `aws configure`). Faster to set up, but the keys never expire on their own. If you go that route, rotate them on a schedule and store them only in `~/.aws/credentials`.

### Step 3 — Install Terraform

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform version
# expect: Terraform v1.6+ ...
```

### Step 4 — Install Docker

```bash
brew install --cask docker
open -a Docker          # launches Docker Desktop; wait for the whale icon to settle
docker version          # confirms the daemon is up
```

If `docker version` reports a connection error, Docker Desktop hasn't finished starting — give it 30 seconds.

### Step 5 — Request an ACM certificate

Pick a subdomain on a domain you control. Examples use `rtms-demo.example.com`.

```bash
aws acm request-certificate \
  --domain-name rtms-demo.example.com \
  --validation-method DNS \
  --region us-east-1
# Returns: { "CertificateArn": "arn:aws:acm:us-east-1:...:certificate/<uuid>" }
```

Save the ARN. Fetch the DNS validation record AWS needs:

```bash
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:...:certificate/<uuid> \
  --region us-east-1 \
  --query 'Certificate.DomainValidationOptions[].ResourceRecord'
# Returns: [ { "Name": "_abc123.rtms-demo.example.com.", "Type": "CNAME", "Value": "_xyz789.acm-validations.aws." } ]
```

At your DNS provider (Cloudflare / Route 53 / GoDaddy / Namecheap), add a CNAME record:
- **Name**: `_abc123.rtms-demo` *(strip the trailing `.YOUR-DOMAIN.com.` your provider already adds)*
- **Value**: `_xyz789.acm-validations.aws`
- **TTL**: default (300s is fine)
- On Cloudflare: set proxy to **DNS only** (gray cloud), not Proxied

Then poll until issued:

```bash
# Use `cert_status` (not `status` — zsh treats `$status` as read-only).
while true; do
  cert_status=$(aws acm describe-certificate \
    --certificate-arn <ARN> --region us-east-1 \
    --query 'Certificate.Status' --output text)
  echo "$(date +%T) — $cert_status"
  [ "$cert_status" = "ISSUED" ] && break
  sleep 30
done
```

### Step 6 — Create the three Zoom secrets in Secrets Manager

Use the same values that worked locally:

```bash
aws secretsmanager create-secret --name rtms/zm-rtms-client \
  --secret-string '<your ZM_RTMS_CLIENT>' --region us-east-1

aws secretsmanager create-secret --name rtms/zm-rtms-secret \
  --secret-string '<your ZM_RTMS_SECRET>' --region us-east-1

aws secretsmanager create-secret --name rtms/zm-rtms-webhook-secret \
  --secret-string '<your ZM_RTMS_WEBHOOK_SECRET>' --region us-east-1
```

Each command returns an ARN. Save all three — they go into `terraform.tfvars` in Step 9.

### Step 7 — Build and push the worker image to ECR

The ECS task can't start until the container image exists in a registry. A helper script creates a private ECR repo and pushes the image to it:

```bash
AWS_REGION=us-east-1 PROJECT_NAME=rtms-demo TAG=0.1.0 \
  bash scripts/build-and-push-worker.sh
```

The script ends with:

```
worker_image = "<acct-id>.dkr.ecr.us-east-1.amazonaws.com/rtms-demo-worker:0.1.0"
```

Copy that string — it goes into `terraform.tfvars` in Step 9.

### Step 8 — Bootstrap the Terraform state backend

Terraform stores its state in S3 (with DynamoDB locking). The bootstrap script creates both:

```bash
AWS_REGION=us-east-1 PROJECT_NAME=rtms-demo \
  bash scripts/bootstrap-state.sh
```

The script ends by printing the `terraform init` command you'll run in Step 10. Copy it.

### Step 9 — Configure `terraform.tfvars`

```bash
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in:

| Variable | Value |
|---|---|
| `zm_rtms_client_secret_arn` | ARN from Step 6, first command |
| `zm_rtms_secret_secret_arn` | ARN from Step 6, second command |
| `zm_rtms_webhook_secret_secret_arn` | ARN from Step 6, third command |
| `acm_certificate_arn` | ARN from Step 5 |
| `webhook_domain` | `rtms-demo.YOUR-DOMAIN.com` (the subdomain you picked in Step 5) |
| `worker_image` | The ECR URI from Step 7 |
| `budget_alert_email` | Where to send the AWS Budgets 80% alert |

### Step 10 — `terraform init` and `apply`

Paste the `terraform init` command from Step 8, then plan and apply:

```bash
terraform init \
  -backend-config="bucket=rtms-demo-tfstate-<your-acct-id>" \
  -backend-config="key=rtms-demo/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"

terraform plan          # eyeball what'll be created
terraform apply         # ~6–8 minutes
```

When it finishes, copy the outputs:

```
alb_dns_name      = "rtms-demo-alb-12345.us-east-1.elb.amazonaws.com"
webhook_url       = "https://rtms-demo.YOUR-DOMAIN.com"
transcript_bucket = "rtms-demo-transcripts-abcd1234"
ecs_cluster_name  = "rtms-demo-cluster"
log_group_name    = "/aws/ecs/rtms-demo-worker"
```

### Step 11 — Point your subdomain at the ALB

Back at your DNS provider, add a second record (or update the existing CNAME):

| Type | Name | Value |
|---|---|---|
| `CNAME` *(or Route 53 `A`-ALIAS)* | `rtms-demo` | the `alb_dns_name` from Step 10 |

Verify the TLS path works:

```bash
curl -I https://rtms-demo.YOUR-DOMAIN.com/
# Expect HTTP 4xx (the SDK doesn't handle GET requests)
# CRITICALLY: no TLS error — that confirms ACM + ALB + DNS are wired up
```

### Step 12 — Update the Zoom Marketplace webhook URL

In the Marketplace app's **Event Subscription**, change the endpoint from your ngrok URL to:

```
https://rtms-demo.YOUR-DOMAIN.com
```

Click **Validate** in the Marketplace UI. Zoom posts an `endpoint.url_validation` event to the worker; if HMAC works, you'll see green within seconds.

### Step 13 — Run a real test

In one terminal, tail the worker logs:

```bash
aws logs tail /aws/ecs/rtms-demo-worker --follow --region us-east-1
```

In another, start watching S3:

```bash
watch -n 5 'aws s3 ls s3://<your-transcript-bucket>/transcripts/ --recursive --region us-east-1 | tail -20'
```

Then start a Zoom meeting with RTMS enabled. The log stream should show:

```
webhook arrived → signature valid → client.join() issued → on_join_confirm fired
```

…and `.jsonl` chunks should start landing in S3 the moment anyone speaks.

### Step 14 — Teardown when done

```bash
bash scripts/teardown.sh
```

Empties the transcript bucket, runs `terraform destroy`, and checks for orphaned ENIs. The only thing that bills meaningfully when idle is the ALB (~$16/mo), so run teardown between testing sessions.

