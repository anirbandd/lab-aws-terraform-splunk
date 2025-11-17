# ------------------------------------------------------------------------------
# 1. Terraform Configuration (Backend)
# ------------------------------------------------------------------------------
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # The S3 Backend is required for remote state management.
  # This makes your state highly durable and enables collaboration.
  backend "s3" {
    # NOTE: These values must be hardcoded or passed via CLI/env vars,
    # they cannot use 'var.' references inside the 'backend' block.
    # You must create this S3 bucket manually BEFORE running terraform init.
    bucket         = "my-splunk-lab-terraform-state-bucket-12345" 
    key            = "splunk-lab/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true  # Always encrypt the state file
    # dynamodb_table = "terraform-state-lock" # CRITICAL: Prevents concurrent changes
  }
}

# ------------------------------------------------------------------------------
# 2. AWS Provider Definition
# ------------------------------------------------------------------------------
# This block sets the AWS region for all resources defined in your files.
provider "aws" {
  region = var.aws_region
}