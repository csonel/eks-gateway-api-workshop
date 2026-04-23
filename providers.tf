terraform {
  required_version = ">= 1.12.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95.0"
    }
  }

  # Default: local state (terraform.tfstate in this directory).
  # To use S3 instead, comment out the block below and uncomment the s3 block.

  # backend "s3" {
  #   bucket       = "awscd-tfstates"
  #   key          = "awscdro2026/terraform.tfstate"
  #   region       = "eu-central-1"
  #   profile      = "aws-community-day"   # omit if using environment variables
  #   use_lockfile = true                  # requires Terraform >= 1.10, no DynamoDB needed
  # }
}

provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      Project     = "AWS Community Day Romania 2026"
      Environment = "Dev"
      Service     = "EKS"
    }
  }
}