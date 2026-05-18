terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-wazuh-indexer"
    }
  }
}
