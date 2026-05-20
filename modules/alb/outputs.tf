output "dns_name" {
  value = aws_lb.this.dns_name
}

output "zone_id" {
  description = "ALB hosted zone ID for Route 53 ALIAS records."
  value       = aws_lb.this.zone_id
}

output "arn_suffix" {
  description = "Used in CloudWatch metric dimensions for the ALB."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn" {
  value = aws_lb_target_group.worker.arn
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.worker.arn_suffix
}
