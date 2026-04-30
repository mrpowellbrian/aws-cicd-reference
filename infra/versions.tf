terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 6.0.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0, < 3.0.0"
    }
  }

  # Backend values are injected at init time by the CI workflow:
  #   terraform init \
  #     -backend-config="bucket=$TF_STATE_BUCKET" \
  #     -backend-config="dynamodb_table=terraform-state-lock"
  #
  # For local development, copy backend.hcl.example → backend.hcl and run:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key    = "aws-cicd-reference/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aws-cicd-reference"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
