terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-gcp-VPN-AWS"
    }
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
