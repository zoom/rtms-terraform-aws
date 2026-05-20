output "alb_dns_name" {
  description = "DNS name of the ALB. Point your webhook subdomain (CNAME or Route 53 ALIAS) at this."
  value       = module.alb.dns_name
}

output "webhook_url" {
  description = "Canonical webhook URL to paste into the Zoom Marketplace RTMS app's Event Subscription endpoint."
  value       = "https://${var.webhook_domain}"
}

output "transcript_bucket" {
  description = "S3 bucket where transcript JSONL lands at transcripts/<meeting_uuid>/<ms-epoch>.jsonl."
  value       = module.storage.bucket_name
}

output "ecs_cluster_name" {
  description = "ECS cluster name for `aws ecs` debugging commands."
  value       = module.worker.cluster_name
}

output "ecs_service_name" {
  description = "ECS service name for `aws ecs` debugging commands."
  value       = module.worker.service_name
}

output "log_group_name" {
  description = "CloudWatch log group containing worker logs."
  value       = module.worker.log_group_name
}

output "worker_security_group_id" {
  description = "Security group attached to worker tasks (for adding manual rules during debugging)."
  value       = module.network.worker_security_group_id
}
