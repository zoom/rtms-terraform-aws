## ─── DNS / ACM ────────────────────────────────────────────────────────────
##
## Two modes (see variables.tf for explanation):
##   dns_mode = "route53"  → issue + validate cert via Route 53, create ALB ALIAS
##   dns_mode = "external" → use customer-provided cert; customer points DNS manually

locals {
  route53_mode = var.dns_mode == "route53"
}

# Validate inputs early — fail with a clear error if the wrong combination is set
check "dns_inputs" {
  assert {
    condition     = !local.route53_mode || var.route53_zone_id != null
    error_message = "dns_mode = 'route53' requires route53_zone_id."
  }
  assert {
    condition     = local.route53_mode || var.acm_certificate_arn != null
    error_message = "dns_mode = 'external' requires acm_certificate_arn (a pre-issued cert for webhook_domain)."
  }
}

# Route 53 mode: create + validate the ACM certificate ourselves
resource "aws_acm_certificate" "this" {
  count             = local.route53_mode ? 1 : 0
  domain_name       = var.webhook_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.project_name}-cert" }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.route53_mode ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.route53_mode ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# Route 53 mode: ALB ALIAS record (created after the ALB module below)
resource "aws_route53_record" "alb_alias" {
  count   = local.route53_mode ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.webhook_domain
  type    = "A"

  alias {
    name                   = module.alb.dns_name
    zone_id                = module.alb.zone_id
    evaluate_target_health = false
  }
}

# Effective cert ARN: ours if we issued it, customer's if they brought it
locals {
  effective_acm_certificate_arn = local.route53_mode ? aws_acm_certificate_validation.this[0].certificate_arn : var.acm_certificate_arn
}

## ─── modules ──────────────────────────────────────────────────────────────

module "network" {
  source = "./modules/network"

  project_name       = var.project_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

module "storage" {
  source = "./modules/storage"

  project_name  = var.project_name
  force_destroy = var.transcript_bucket_force_destroy
}

module "alb" {
  source = "./modules/alb"

  project_name          = var.project_name
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.network.alb_security_group_id
  acm_certificate_arn   = local.effective_acm_certificate_arn
}

module "worker" {
  source = "./modules/worker"

  project_name           = var.project_name
  worker_image           = var.worker_image
  task_cpu               = var.task_cpu
  task_memory            = var.task_memory
  min_capacity           = var.min_capacity
  max_capacity           = var.max_capacity
  cpu_target_utilization = var.cpu_target_utilization
  spot_weight            = var.spot_weight
  ondemand_weight        = var.ondemand_weight
  log_retention_days     = var.log_retention_days

  public_subnet_ids        = module.network.public_subnet_ids
  worker_security_group_id = module.network.worker_security_group_id
  target_group_arn         = module.alb.target_group_arn

  transcript_bucket     = module.storage.bucket_name
  transcript_bucket_arn = module.storage.bucket_arn

  zm_rtms_client_secret_arn         = var.zm_rtms_client_secret_arn
  zm_rtms_secret_secret_arn         = var.zm_rtms_secret_secret_arn
  zm_rtms_webhook_secret_secret_arn = var.zm_rtms_webhook_secret_secret_arn

  zoom_host                 = var.zoom_host
  eventloop_threads         = var.eventloop_threads
  callback_executor_workers = var.callback_executor_workers
  transcript_flush_interval = var.transcript_flush_interval
  log_level                 = var.log_level
}

module "observability" {
  source = "./modules/observability"

  project_name            = var.project_name
  ecs_cluster_name        = module.worker.cluster_name
  ecs_service_name        = module.worker.service_name
  alb_arn_suffix          = module.alb.arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix

  monthly_budget_usd = var.monthly_budget_usd
  budget_alert_email = var.budget_alert_email
}
