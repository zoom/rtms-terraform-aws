variable "project_name" {
  type = string
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete the bucket even when non-empty."
  type        = bool
  default     = false
}
