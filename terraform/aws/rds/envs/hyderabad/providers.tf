terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-RDS"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Hyderabad 리전용 AWS Provider
provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Owner       = "st1"
    Project     = "msp-solution-architect"
    Team        = "k2p"
    Environment = "dev"
  }
}
