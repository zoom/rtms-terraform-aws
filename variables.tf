## Identity / region

variable "aws_region" {
  description = "AWS region to deploy into. us-east-1 is typically cheapest."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as the prefix for every resource."
  type        = string
  default     = "rtms-demo"
}

variable "environment" {
  description = "Logical environment tag value."
  type        = string
  default     = "demo"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Project = "rtms-demo"
  }
}

## Zoom RTMS credential ARNs (created out-of-band in Secrets Manager)

variable "zm_rtms_client_secret_arn" {
  description = "ARN of the Secrets Manager secret holding ZM_RTMS_CLIENT."
  type        = string
}

variable "zm_rtms_secret_secret_arn" {
  description = "ARN of the Secrets Manager secret holding ZM_RTMS_SECRET."
  type        = string
}

variable "zm_rtms_webhook_secret_secret_arn" {
  description = "ARN of the Secrets Manager secret holding ZM_RTMS_WEBHOOK_SECRET."
  type        = string
}

## TLS / DNS
##
## Two modes:
##   dns_mode = "route53"  → customer's domain is hosted in Route 53; this template
##                            creates the ACM cert, validates it via Route 53 DNS, and
##                            creates the ALB ALIAS record automatically. Customer only
##                            provides webhook_domain + route53_zone_id.
##   dns_mode = "external" → customer's DNS is hosted elsewhere (Squarespace, Cloudflare,
##                            GoDaddy, etc.). Customer pre-issues an ACM cert, validates it
##                            manually via their DNS provider, and provides the cert ARN.
##                            After apply, customer points their DNS at the alb_dns_name
##                            output manually.

variable "dns_mode" {
  description = "How to handle DNS for the webhook subdomain. 'route53' is the magic path (recommended); 'external' is for any other DNS provider."
  type        = string
  default     = "route53"
  validation {
    condition     = contains(["route53", "external"], var.dns_mode)
    error_message = "dns_mode must be 'route53' or 'external'."
  }
}

variable "webhook_domain" {
  description = "DNS name Zoom posts webhooks to (e.g. rtms.example.com). Required in both modes."
  type        = string
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for the parent domain. Required when dns_mode = 'route53'. Ignored otherwise."
  type        = string
  default     = null
}

variable "acm_certificate_arn" {
  description = "ARN of a pre-issued ACM certificate for webhook_domain. Required when dns_mode = 'external'. Ignored when dns_mode = 'route53' (this template issues + validates one for you)."
  type        = string
  default     = null
}

## Zoom host (commercial vs ZfG)

variable "zoom_host" {
  description = "Zoom host the worker connects to. Commercial: https://zoom.us. Government: https://zoomgov.com."
  type        = string
  default     = "https://zoom.us"
}

## Worker container image

variable "worker_image" {
  description = "Container image URI for the worker. Default is the published image on ECR Public — customers can use this as-is without Docker installed locally."
  type        = string
  default     = "public.ecr.aws/t3b9e0y5/rtms-worker:1.1.0"
}

## Networking

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread subnets across. Two is sufficient for the demo."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

## Worker capacity

variable "task_cpu" {
  description = "Fargate task CPU units (256 | 512 | 1024 | 2048 | 4096)."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory (MB). Must match CPU per Fargate rules."
  type        = number
  default     = 1024
}

variable "min_capacity" {
  description = "Minimum ECS service task count."
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum ECS service task count."
  type        = number
  default     = 20
}

variable "cpu_target_utilization" {
  description = "Target CPU% for ECS auto-scaling target tracking."
  type        = number
  default     = 50
}

## Fargate Spot vs on-demand

variable "spot_weight" {
  description = "Capacity provider weight for FARGATE_SPOT."
  type        = number
  default     = 1
}

variable "ondemand_weight" {
  description = "Capacity provider weight for FARGATE (on-demand). Set > 0 to mix Spot + on-demand."
  type        = number
  default     = 0
}

## Worker runtime tuning (passed through as container env vars)

variable "eventloop_threads" {
  description = "rtms.EventLoopPool thread count per task."
  type        = number
  default     = 2
}

variable "callback_executor_workers" {
  description = "ThreadPoolExecutor size for offloaded callbacks (S3 PUTs, etc.)."
  type        = number
  default     = 16
}

variable "transcript_flush_interval" {
  description = "Seconds between transcript flushes. (Currently one-PUT-per-chunk; retained for future buffering.)"
  type        = number
  default     = 30
}

variable "log_level" {
  description = "Python log level for the worker."
  type        = string
  default     = "INFO"
}

## Storage / logging

variable "transcript_bucket_force_destroy" {
  description = "Allow `terraform destroy` to delete the bucket even if non-empty. Set to false in production."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the worker log group."
  type        = number
  default     = 30
}

## Cost guardrail

variable "monthly_budget_usd" {
  description = "AWS Budgets monthly cap, in USD. Triggers an email at 80%."
  type        = number
  default     = 50
}

variable "budget_alert_email" {
  description = "Email address to receive AWS Budgets alerts."
  type        = string
}
