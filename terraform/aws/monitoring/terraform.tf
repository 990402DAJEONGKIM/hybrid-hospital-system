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
    # #260609 박경수 — Cloudflare DNS 관리용 provider 추가
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    # #260609 박경수 end
  }
}
