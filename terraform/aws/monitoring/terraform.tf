#terraform.tf
terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-aws-monotoring"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
