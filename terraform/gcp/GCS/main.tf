###############################################################
# TC-gcp-storage  /  Cloud SQL → GCS 덤프
#
# 흐름:
#   Cloud Scheduler (매일 KST 02:00)
#     → Cloud SQL Admin API (네이티브 export)
#       → GCS hospital-daily.sql.gz
#          (버저닝으로 30일치 보관)
###############################################################

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  cloud {
    organization = "k2p"
    workspaces { name = "TC-gcp-GCS" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.gcp_region
}


# ─────────────────────────────────────────────────────────
# GCS 덤프 버킷
# ─────────────────────────────────────────────────────────
resource "google_storage_bucket" "db_dumps" {
  name          = "${var.project_id}-hospital-db-dumps"
  location      = var.gcp_region
  storage_class = "STANDARD"
  force_destroy = false

  # 버저닝: 매일 덮어쓰되 이전 버전으로 30일치 보관
  versioning {
    enabled = true
  }

  # 현재 버전: 삭제 안 함 (항상 최신 1개 유지)
  # 이전 버전: 30일 후 삭제
  lifecycle_rule {
    action { type = "Delete" }
    condition {
      age        = 30
      with_state = "ARCHIVED"
    }
  }

  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  labels = {
    project = "msp-hospital"
    purpose = "cloud-sql-dump"
  }
}


# ─────────────────────────────────────────────────────────
# Cloud SQL 서비스 계정 → GCS 쓰기 권한
# ─────────────────────────────────────────────────────────
data "google_sql_database_instance" "cloud_sql" {
  name = var.cloud_sql_instance_name
}

resource "google_storage_bucket_iam_member" "cloud_sql_writer" {
  bucket = google_storage_bucket.db_dumps.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${data.google_sql_database_instance.cloud_sql.service_account_email_address}"
}


# ─────────────────────────────────────────────────────────
# Cloud Scheduler 서비스 계정
# ─────────────────────────────────────────────────────────
resource "google_service_account" "scheduler" {
  account_id   = "cloud-sql-dump-scheduler"
  display_name = "Cloud SQL Dump Scheduler SA"
}

resource "google_project_iam_member" "scheduler_sql_admin" {
  project = var.project_id
  role    = "roles/cloudsql.admin"
  member  = "serviceAccount:${google_service_account.scheduler.email}"
}


# ─────────────────────────────────────────────────────────
# Cloud Scheduler: Cloud SQL → GCS 매일 KST 02:00
#
# 파일명 hospital-daily.sql.gz 으로 매일 덮어씀
# → GCS 버저닝으로 이전 30일치 자동 보관
# ─────────────────────────────────────────────────────────
resource "google_cloud_scheduler_job" "cloud_sql_dump" {
  name             = "cloud-sql-daily-dump"
  description      = "Cloud SQL hospital DB 매일 02:00 KST → GCS"
  schedule         = "0 17 * * *"   # UTC 17:00 = KST 02:00
  time_zone        = "Asia/Seoul"
  attempt_deadline = "600s"

  http_target {
    http_method = "POST"
    uri = join("/", [
      "https://sqladmin.googleapis.com/sql/v1beta4/projects",
      var.project_id,
      "instances",
      var.cloud_sql_instance_name,
      "export",
    ])

    body = base64encode(jsonencode({
      exportContext = {
        kind      = "sql#exportContext"
        fileType  = "SQL"
        uri       = "gs://${google_storage_bucket.db_dumps.name}/hospital-daily.sql.gz"
        databases = ["hospital"]
        sqlExportOptions = {
          schemaOnly = false
        }
      }
    }))

    headers = { "Content-Type" = "application/json" }

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }
}


# ─────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────
output "gcs_bucket_name" {
  value       = google_storage_bucket.db_dumps.name
  description = "GCS 덤프 버킷 이름"
}

output "dump_file_path" {
  value       = "gs://${google_storage_bucket.db_dumps.name}/hospital-daily.sql.gz"
  description = "매일 덮어쓰이는 덤프 파일 경로 (이전 버전은 GCS 버저닝으로 보관)"
}
