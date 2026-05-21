terraform {
  required_version = ">= 1.10" # use_lockfile for S3-native state locking

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Customer fills these in via `terraform init -backend-config=...` after
  # running scripts/bootstrap-state.sh to create the bucket + lock table.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  # Merge the Environment tag in last so var.environment always wins,
  # even if a caller passes a different Environment value in var.tags.
  default_tags {
    tags = merge(var.tags, { Environment = var.environment })
  }
}
