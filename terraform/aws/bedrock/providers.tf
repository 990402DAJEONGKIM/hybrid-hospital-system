terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-aws-Bedrock"
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

# Bedrock Knowledge Base / OpenSearch Serverless는 ap-south-2 미지원 → us-east-1
provider "aws" {
  alias  = "bedrock"
  region = var.bedrock_region
}

locals {
  common_tags = {
    Owner       = "st4"
    Project     = "msp-solution-architect"
    Team        = "k2p"
    Environment = "dev"
  }
}
