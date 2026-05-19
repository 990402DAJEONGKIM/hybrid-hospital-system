terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-aws-RDS"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

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
