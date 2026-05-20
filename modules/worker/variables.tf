variable "project_name" { type = string }
variable "worker_image" { type = string }

variable "task_cpu" { type = number }
variable "task_memory" { type = number }
variable "min_capacity" { type = number }
variable "max_capacity" { type = number }
variable "cpu_target_utilization" { type = number }
variable "spot_weight" { type = number }
variable "ondemand_weight" { type = number }
variable "log_retention_days" { type = number }

# Networking refs from the network module
variable "public_subnet_ids" { type = list(string) }
variable "worker_security_group_id" { type = string }

# Load balancer target group
variable "target_group_arn" { type = string }

# Storage refs from the storage module
variable "transcript_bucket" { type = string }
variable "transcript_bucket_arn" { type = string }

# Secrets Manager ARNs (created out-of-band by the customer)
variable "zm_rtms_client_secret_arn" { type = string }
variable "zm_rtms_secret_secret_arn" { type = string }
variable "zm_rtms_webhook_secret_secret_arn" { type = string }

# Runtime tuning (env vars)
variable "zoom_host" { type = string }
variable "eventloop_threads" { type = number }
variable "callback_executor_workers" { type = number }
variable "transcript_flush_interval" { type = number }
variable "log_level" { type = string }
