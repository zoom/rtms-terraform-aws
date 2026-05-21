# RTMS on AWS: Terraform Template

Deploy a scalable Zoom **RealTime Media Streaming (RTMS)** consumer to AWS in one command. Same shape as the [`rtms-quickstart-py`](https://github.com/zoom/rtms-quickstart-py) repo — `@rtms.on_webhook_event` + `rtms.run()` — packaged into a Fargate container, fronted by an ALB, and configured to auto-scale.

---

## Architecture

```
Zoom ──webhook──▶  ALB (HTTPS, ACM cert)  ──▶  ECS Fargate Service
                                                ├── Task 1  (worker/main.py)
                                                ├── Task 2  (worker/main.py)
                                                └── Task N  (worker/main.py)
                                                            │
                                              ┌─────────────┼──────────────┐
                                              ▼             ▼              ▼
                                          S3 (JSONL)  CloudWatch     Secrets Manager
```

Each task runs `worker/main.py`, which uses `@rtms.on_webhook_event` to receive Zoom webhooks on port 8080 and `rtms.EventLoopPool(threads=2)` to host the active meetings. The ECS service auto-scales on CPU.

---

### Prerequisites

Tools (one-time install):

```bash
brew install awscli terraform jq            # macOS
# Linux: use your package manager equivalents
```

Then `aws configure` (or `aws sso login`) once so the CLI is authenticated. No Docker required — the default `worker_image` pulls a pre-built public image.

Accounts / external assets:

- **AWS account** with admin access. `us-east-1` is the default deploy region.
- **A domain you control** (Route 53 preferred, but any provider works — see DNS modes below).
- **Zoom Marketplace RTMS app** with Client ID, Client Secret, and Webhook Secret Token. Events subscribed: `endpoint.url_validation`, `meeting.rtms_started`, `meeting.rtms_stopped`, `meeting.rtms_interrupted`.

---

## Quick Start

```bash
git clone https://github.com/zoom/rtms-terraform-aws.git
cd rtms-terraform-aws
./deploy.sh
```

That's it. The script prompts for the values it needs, creates everything (Secrets Manager, Terraform state, infrastructure), and prints your webhook URL when it's done. End-to-end: **~10 minutes**.

Re-running `./deploy.sh` is safe — it preserves your `terraform.tfvars`, skips Secrets Manager entries and state buckets that already exist, and only `terraform apply`s if there's drift.

### What you'll be prompted for

| Field | What |
|---|---|
| AWS region | Defaults to `us-east-1` (cheapest) |
| Project name | Resource prefix; defaults to `rtms-demo` |
| Webhook subdomain | e.g. `rtms.example.com` — the FQDN Zoom posts to |
| DNS mode | `route53` (recommended, fully automated) or `external` (you handle DNS) |
| Route 53 zone ID *or* ACM cert ARN | Depending on DNS mode (see below) |
| Zoom Client ID | From your Marketplace RTMS app |
| Zoom Client Secret | Same |
| Zoom Webhook Secret Token | Same |
| Budget alert email | For the AWS Budgets 80% notification |



### Prefer to run each step manually?

See [docs/MANUAL_SETUP.md](docs/MANUAL_SETUP.md) for the step-by-step walkthrough that `deploy.sh` automates.


## DNS modes

Two ways to handle DNS for your webhook subdomain. `deploy.sh` asks at startup; you can also flip via the `dns_mode` tfvar.

| Mode | When to use | What you provide | What Terraform creates |
|---|---|---|---|
| **`route53`** (default, recommended) | Your domain is hosted in Route 53 | `route53_zone_id` + `webhook_domain` | ACM cert, DNS-validation CNAME, ALB ALIAS — fully automated, no manual DNS clicks |
| **`external`** | Your DNS is at Squarespace, Cloudflare, GoDaddy, etc. | `acm_certificate_arn` (you pre-issue + DNS-validate the cert) + `webhook_domain` | Nothing DNS-related. You manually point your DNS at the `alb_dns_name` output after apply. |

### How to find your Route 53 zone ID

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='example.com.'].Id" \
  --output text
# returns: /hostedzone/Z01234567ABCDEFGH  (deploy.sh strips the prefix)
```

### External mode setup

1. Request the cert in the same region you'll deploy to:
   ```bash
   aws acm request-certificate \
     --domain-name rtms.example.com \
     --validation-method DNS \
     --region us-east-1
   ```
2. AWS returns a CNAME record to add at your DNS provider. Add it.
3. Poll until `Certificate.Status` is `"ISSUED"`.
4. Pass the cert ARN into `deploy.sh` when it prompts.
5. After `terraform apply`, create a CNAME at your DNS provider pointing your subdomain at the `alb_dns_name` output.

---

## What's deployed

| Resource | Purpose |
|---|---|
| **VPC** (2 AZs) | Networking foundation. Default profile uses **public subnets** for cost; flip `use_private_subnets = true` for production. |
| **ALB** | Public HTTPS endpoint. Terminates TLS via your ACM cert. Health check: `GET /` matcher `200-299` (worker returns 200 to GET via SDK monkey-patch — see DEVS-X9 v1.2 work). |
| **ACM cert + Route 53 records** (route53 mode only) | Issued, DNS-validated, and ALIAS-linked to the ALB automatically. |
| **ECS cluster + Fargate service** | Runs the worker container. Min 1 task, max 20 by default. |
| **Auto-scaling policy** | Target tracking on CPU at 50%. |
| **S3 bucket** | Transcript JSONL at `transcripts/<meeting_uuid>/<ns-epoch>.jsonl` (one PUT per chunk). SSE-S3, versioned, 30-day lifecycle to Glacier IR. |
| **CloudWatch log group** | `/aws/ecs/<project>-worker`, 30-day retention. |
| **CloudWatch alarms** | ALB 5xx > 5/min, no healthy hosts, ECS service unhealthy. |
| **CloudWatch dashboard** | ALB requests + 5xx, ECS CPU + memory, ALB healthy host count. |
| **AWS Budgets alert** | 80% + 100% of `monthly_budget_usd` → email. |
| **Secrets Manager references** | Three pre-existing secrets injected into the task as env vars. |

---

## Outputs

After `deploy.sh` (or `terraform apply`) finishes:

| Output | Use |
|---|---|
| `webhook_url` | Paste into Zoom Marketplace → Event Subscriptions |
| `alb_dns_name` | Point your DNS record here (external mode only) |
| `transcript_bucket` | Where `.jsonl` transcripts land |
| `ecs_cluster_name` / `ecs_service_name` | For `aws ecs` debugging |
| `log_group_name` | CloudWatch Logs Insights queries |

---

## Cost

| State | Approx. monthly |
|---|---|
| **Idle (0 meetings)** | ~$20 — ALB (~$16) + 1 Fargate Spot task (~$2) + misc (~$2) |
| **10 concurrent × 1 hr/day** | ~$22 |
| **100 concurrent × 1 hr/day** | ~$30 |

A `monthly_budget_usd` tfvar wires up an AWS Budgets alert at 80%. Run `bash scripts/teardown.sh` when not testing — the ALB is the only resource that bills meaningfully when idle.

### Low-cost test recipe

- Fresh AWS account in `us-east-1`
- `max_capacity = 2`, `task_cpu = 256`, `task_memory = 512`
- `terraform destroy` immediately after each session
- Realistic budget: **~$3 for a full end-to-end test pass**

---

## Local Development

```bash
cd worker
python3 -m venv .venv && source .venv/bin/activate   # or: uv venv && source .venv/bin/activate
pip install -r requirements-dev.txt                  # or: uv pip install -r requirements-dev.txt
pytest                                               # 48 tests, ~1 second
```

The same `worker/main.py` runs locally. Two env-file templates are committed:

| File | When to use it |
|---|---|
| [.env.development.example](.env.development.example) | Local dev. `progressive` SDK logs, `DEBUG` Python logs, faster reconnect backoff. Copy to `.env.development`. |
| [.env.example](.env.example) | Production-shaped. `json` SDK logs for CloudWatch, `INFO` Python logs. Copy to `.env`. |

`main.py` loads `.env` first, then `.env.development` overrides — so the dev file always wins locally and you can't accidentally use prod credentials when developing. Both real files are gitignored. In Fargate neither exists; secrets come from Secrets Manager.

> **`.env` files are local-only.** In production (Fargate, EC2, Kubernetes, anywhere customer-facing), secrets must come from AWS Secrets Manager via the ECS task definition's `secrets` block — never baked into a Docker image, never copied onto a server, never committed to git. The Terraform in this repo wires Secrets Manager → ECS automatically; `deploy.sh` handles populating Secrets Manager from your input (or detects existing entries by name and re-uses them).

Point an ngrok tunnel at port 8080 to receive Zoom webhooks locally.

---

## Test Plan

```bash
# Webhook URL validation (CRC handshake — no real meeting needed)
bash scripts/send-test-webhook.sh validation
# expect: HTTP 200 with {"plainToken": ..., "encryptedToken": ...}

# HMAC signature rejection
bash scripts/send-test-webhook.sh invalid
# expect: HTTP 401; check the WebhookSignatureFailed CloudWatch metric

# Real RTMS smoke — start a Zoom meeting with RTMS on, then:
aws logs tail /aws/ecs/rtms-demo-worker --follow
aws s3 ls s3://<transcript_bucket>/transcripts/ --recursive

# Autoscale check — synth load via a small loop of webhooks
bash scripts/send-test-webhook.sh burst 20
aws ecs describe-services --cluster rtms-demo-cluster --services rtms-demo-worker \
  --query 'services[0].desiredCount'

# Failover — stop a running task, watch ECS replace it within ~60s
aws ecs list-tasks --cluster rtms-demo-cluster
aws ecs stop-task --cluster rtms-demo-cluster --task <task-arn>
```

---

## Teardown

```bash
bash scripts/teardown.sh
```

Force-empties the S3 bucket, runs `terraform destroy`, and verifies no orphaned ENIs remain.

---

## Failure Modes & Trade-offs (v1)

This is a **POC reference**, not a production-hardened deployment. Key trade-offs you should know about:

### What the worker handles (RTMS-level reconnection)

Per [Zoom's RTMS reconnection contract](https://developers.zoom.us/docs/rtms/meetings/work-with-streams/#failover-and-reconnection), the worker handles all three failover scenarios using the SDK's events (not raw WebSockets):

| Scenario | Trigger | Worker action |
|---|---|---|
| **1. RTMS server failure** | `meeting.rtms_started` arrives with same `rtms_stream_id` but different `server_urls` | Leave old client, join with new payload |
| **2. Signal connection down** | `meeting.rtms_interrupted` webhook | Leave old client, join with the webhook's fresh credentials |
| **3. Media connection down only** | SDK `on_media_connection_interrupted` callback | Re-issue `client.join(stored_payload)` with exponential backoff (3s/6s/12s/24s/30s) up to 5 attempts |

Reference: [zoom/rtms-samples/rtms_api/reconnection_and_chaos_mode_js](https://github.com/zoom/rtms-samples/tree/main/rtms_api/reconnection_and_chaos_mode_js) — same contract, raw-WebSocket implementation. Our worker does it through SDK callbacks.

### What AWS handles (infrastructure-level failover)

- **Task crash** → ECS replaces the task within ~60s. In-flight meetings on the dead task are dropped (webhook is already ack'd, no replay). Future webhooks route to healthy tasks via the ALB.
- **AZ outage** → ECS places replacement tasks in the healthy AZ.
- **Spot interruption** → SIGTERM handler calls `client.leave()` on all active meetings inside the 30s Fargate stop grace; future webhooks land elsewhere.

### Other v1 demo shortcuts

- **Public-subnet workers.** Saves ~$32/mo NAT GW cost. Security group locks ingress to the ALB. For private subnets + NAT, set `use_private_subnets = true`.
- **Fargate Spot.** ~70% cheaper, but tasks can be reclaimed with 2-minute notice. Mix Spot + on-demand via `spot_weight` / `ondemand_weight` for a stable baseline.
- **One S3 PUT per transcript chunk.** Simple to reason about, but produces lots of small objects. Production fix: buffer ~30s in memory and PUT a multi-line JSONL, or stream to Kinesis Firehose.
- **All meeting state lives in worker memory.** This is the most important trade-off to understand. The worker keeps three in-process maps for each active stream — the `rtms.Client` instances (`clients`), the cached webhook payloads used for reconnection (`stream_payloads`), and per-stream reconnect-attempt counters (`reconnect_attempt`). Plus the in-process webhook dedup table. **All of these are lost on task restart.** If a Fargate task crashes mid-meeting (Spot reclaim, OOM, AZ blip), the in-flight meeting drops — the next webhook for that stream lands on a fresh task with no record of the previous join, and Zoom's join signature is time-bound so re-joining isn't always possible. Production fix: SQS-replay architecture where webhook ingest is decoupled from the worker fleet (see [spec.md → Future Work](spec.md)). Cross-task dedup would similarly need DynamoDB / ElastiCache — but the rtms SDK rejects duplicate joins anyway, so per-task dedup is belt-and-suspenders.


---

## Zoom for Government

Set `zoom_host = "https://zoomgov.com"` in `terraform.tfvars`. The worker maps URLs accordingly. ALB / ECS / DNS are unchanged.

---

## Troubleshooting

- **Zoom webhook validation fails**: `ZM_RTMS_WEBHOOK_SECRET` in Secrets Manager must match the Marketplace app's Secret Token exactly. Tail logs: `aws logs tail /aws/ecs/<project>-worker --follow`.
- **ALB returns 502 / 503**: target group health check failing. The ALB hits `GET /` on port 8080; matcher is `200-299` (the worker subclasses `WebhookHandler` to return 200 to GET — without that, the SDK returns 501 which can't match within ALB's allowed 200-499 range).
- **Worker can't pull image**: task execution role missing ECR read, or the image doesn't exist at the URI in `worker_image`. Check the ECR repo + image tag.
- **Transcripts not appearing**: `on_join_confirm` not firing. Usually a Zoom-side scope or RTMS-enablement issue; check the Marketplace app config and confirm `meeting.rtms_started`, `meeting.rtms_stopped`, `meeting.rtms_interrupted` are subscribed events.
- **`failed to open file [/app/logs/...] errno = 2` in logs**: rebuild the worker image — image tag `0.1.3` or later includes `mkdir -p /app/logs` in the Dockerfile. The C++ RTMS SDK writes internal log files to `./logs/` relative to CWD; the container's `WORKDIR /app` resolves that to `/app/logs/` which must exist.
- **`terraform destroy` hangs on VPC**: run `bash scripts/teardown.sh` — it force-deletes Fargate ENIs.

---

## Layout

```
rtms-terraform-aws/
├── deploy.sh                # one-command guided setup
├── README.md                # this file
├── docs/
│   └── MANUAL_SETUP.md      # step-by-step walkthrough (what deploy.sh automates)
├── terraform.tfvars.example # all inputs documented
├── .env.example             # container env-var contract (local dev)
├── .env.development.example # local-dev variant with debug-friendly defaults
├── main.tf / variables.tf / outputs.tf / versions.tf
├── modules/                 # network, alb, worker, storage, observability
├── worker/                  # Python RTMS consumer (Dockerfile + main.py + tests)
├── scripts/
│   ├── bootstrap-state.sh         # S3 backend setup
│   ├── build-and-push-worker.sh   # build + push worker image to ECR
│   ├── send-test-webhook.sh       # signed-webhook smoke harness
│   ├── teardown.sh                # destroy + ENI cleanup
│   └── validate-terraform.sh      # fmt + validate + tflint + checkov
└── .github/                 # dependabot + CI workflows
```
