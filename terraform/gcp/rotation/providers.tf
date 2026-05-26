terraform {
  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-gcp-rotation"
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

locals {
  common_labels = {
    project     = "msp-hospital"
    environment = "dev"
    managed-by  = "terraform"
    team        = "k2p"
  }
}
