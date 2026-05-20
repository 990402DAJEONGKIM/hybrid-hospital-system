terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-gcp-bastion"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
