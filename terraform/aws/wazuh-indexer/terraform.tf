terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-aws-wazuh-indexer"
    }
  }
}
