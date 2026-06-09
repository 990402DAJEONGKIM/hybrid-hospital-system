#provider.tf
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
# #260609 박경수 — Cloudflare provider
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
# #260609 박경수 end
