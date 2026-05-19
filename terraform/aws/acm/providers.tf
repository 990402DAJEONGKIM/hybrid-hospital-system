terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-ACM"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "msp-solution-architect"
      Team        = "k2p"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
