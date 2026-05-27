#terraform.tf
terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-aws-security"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
