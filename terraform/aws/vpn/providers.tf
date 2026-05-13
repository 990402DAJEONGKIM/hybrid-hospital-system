
terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-VPN"
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
  region = var.region

  default_tags {
    tags = {
      Project     = "msp-solution-architect"
      Team        = "k2p"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
