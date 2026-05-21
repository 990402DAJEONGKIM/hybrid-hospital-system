terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-aws-WAF"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Owner       = "st4"
    Project     = "msp-solution-architect"
    Team        = "k2p"
    Environment = "dev"
  }
}
