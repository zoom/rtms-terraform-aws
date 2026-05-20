variable "project_name" { type = string }
variable "ecs_cluster_name" { type = string }
variable "ecs_service_name" { type = string }
variable "alb_arn_suffix" { type = string }
variable "target_group_arn_suffix" { type = string }
variable "monthly_budget_usd" { type = number }
variable "budget_alert_email" { type = string }
