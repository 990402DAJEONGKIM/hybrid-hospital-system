terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-aws-ALB"
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
