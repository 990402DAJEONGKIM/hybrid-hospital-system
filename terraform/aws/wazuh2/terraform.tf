terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-wazuh2"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
