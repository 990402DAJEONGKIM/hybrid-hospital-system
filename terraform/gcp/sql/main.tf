terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Cloud SQL API 활성화
resource "google_project_service" "sqladmin" {
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

# VPC를 이름으로 직접 조회 (vpc 폴더 output 참조 없이 독립 동작)
data "google_compute_network" "main" {
  name = var.vpc_name
}
