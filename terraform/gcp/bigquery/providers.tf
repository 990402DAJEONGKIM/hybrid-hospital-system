terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  cloud {
    organization = "k2p"
    workspaces {
      name = "TC-gcp-bigquery"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  common_labels = {
    project      = "msp-hospital"
    environment  = "dev"
    managed-by   = "terraform"
    team         = "k2p"
  }
}
