terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-wazuh"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
