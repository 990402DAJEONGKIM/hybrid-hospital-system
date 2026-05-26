# =========================================================
# GCP Cloud SQL 비밀번호 자동 로테이션 (ISMS-P 2.5.4)
#
# 대상:
#   - pglogical_repl : Cloud SQL + RDS 양쪽 동시 변경
#   - hospital_app   : Cloud SQL만
#   - postgres       : Cloud SQL만
#
# 흐름:
#   Cloud Scheduler (7일마다 KST 03:00)
#     → Cloud Functions (rotation)
#       → Secret Manager 현재 비밀번호 조회
#       → 새 비밀번호 생성
#       → Cloud SQL ALTER USER
#       → (pglogical_repl만) RDS ALTER USER
#       → Secret Manager 업데이트
# =========================================================


# TFC 실행 SA — Secret Manager 생성 권한
resource "google_project_iam_member" "tfc_secret_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${var.tfc_service_account_email}"
}

# TFC 실행 SA — Artifact Registry 생성 권한
resource "google_project_iam_member" "tfc_artifactregistry_admin" {
  project = var.project_id
  role    = "roles/artifactregistry.admin"
  member  = "serviceAccount:${var.tfc_service_account_email}"
}

# TFC 실행 SA — VPC Access Connector 생성 권한
resource "google_project_iam_member" "tfc_vpcaccess_admin" {
  project = var.project_id
  role    = "roles/vpcaccess.admin"
  member  = "serviceAccount:${var.tfc_service_account_email}"
}

# TFC 실행 SA — Cloud Functions 생성 권한
resource "google_project_iam_member" "tfc_cloudfunctions_admin" {
  project = var.project_id
  role    = "roles/cloudfunctions.admin"
  member  = "serviceAccount:${var.tfc_service_account_email}"
}

# Cloud Build SA — Artifact Registry 이미지 push 권한
resource "google_project_iam_member" "cloudbuild_artifactregistry_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${data.google_project.current.number}@cloudbuild.gserviceaccount.com"
}

# Cloud Functions 런타임 SA — Secret 읽기 권한
resource "google_project_iam_member" "rotation_secret_reader" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.rotation_fn.email}"
}


# ─────────────────────────────────────────────────────────
# Secret Manager — AWS 자격증명 (ISMS-P 2.5.4)
# ─────────────────────────────────────────────────────────
resource "google_secret_manager_secret" "aws_access_key_id" {
  secret_id = "aws-access-key-id"
  project   = var.project_id
  replication { 
    auto {} 
    }
  labels = local.common_labels
}

resource "google_secret_manager_secret_version" "aws_access_key_id" {
  secret      = google_secret_manager_secret.aws_access_key_id.id
  secret_data = var.aws_access_key_id
}

resource "google_secret_manager_secret" "aws_secret_access_key" {
  secret_id = "aws-secret-access-key"
  project   = var.project_id
  replication {
     auto {} 
     }
  labels = local.common_labels
}

resource "google_secret_manager_secret_version" "aws_secret_access_key" {
  secret      = google_secret_manager_secret.aws_secret_access_key.id
  secret_data = var.aws_secret_access_key
}
# ─────────────────────────────────────────────────────────
# Secret Manager — postgres 신규 등록
# (repl, app은 기존 시크릿 유지 — data source로 참조)
# ─────────────────────────────────────────────────────────
resource "google_secret_manager_secret" "postgres_password" {
  secret_id = local.secret_postgres_name
  project   = var.project_id

  replication {
    auto {}
  }

  labels = local.common_labels
}

resource "google_secret_manager_secret_version" "postgres_password_initial" {
  secret      = google_secret_manager_secret.postgres_password.id
  secret_data = var.postgres_initial_password
}


# ─────────────────────────────────────────────────────────
# Artifact Registry — Cloud Functions 이미지 저장
# ─────────────────────────────────────────────────────────
resource "google_artifact_registry_repository" "rotation" {
  repository_id = local.repo_name
  location      = var.region
  format        = "DOCKER"
  project       = var.project_id

  labels = local.common_labels
}


# ─────────────────────────────────────────────────────────
# Service Account — Cloud Functions 실행용
# ─────────────────────────────────────────────────────────
resource "google_service_account" "rotation_fn" {
  account_id   = "gcp-sa-cloudsql-rotation"
  display_name = "Cloud SQL Rotation Function SA"
  project      = var.project_id
}

# Secret Manager 읽기/쓰기
resource "google_project_iam_member" "rotation_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretVersionManager"
  member  = "serviceAccount:${google_service_account.rotation_fn.email}"
}

# Cloud SQL 접속 (Cloud SQL Client)
resource "google_project_iam_member" "rotation_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.rotation_fn.email}"
}

# Cloud Functions 로그 쓰기
resource "google_project_iam_member" "rotation_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.rotation_fn.email}"
}


# ─────────────────────────────────────────────────────────
# VPC Connector — Cloud Functions → Cloud SQL (PSA)
# ─────────────────────────────────────────────────────────
resource "google_vpc_access_connector" "rotation" {
  name          = "gcp-vpc-conn-rotation"
  region        = var.region
  project       = var.project_id
  network       = data.google_compute_network.main.name
  ip_cidr_range = "10.10.2.0/28"   # 미사용 대역
  min_instances = 2
  max_instances = 3
}


# ─────────────────────────────────────────────────────────
# Cloud Functions (2nd gen) — 비밀번호 로테이션
# ─────────────────────────────────────────────────────────
resource "google_cloudfunctions2_function" "rotation" {
  name     = local.fn_rotation_name
  location = var.region
  project  = var.project_id

  build_config {
    runtime     = "python311"
    entry_point = "rotate_passwords"

    source {
      storage_source {
        bucket = google_storage_bucket.fn_source.name
        object = google_storage_bucket_object.fn_source.name
      }
    }
  }

  service_config {
    service_account_email = google_service_account.rotation_fn.email
    timeout_seconds       = 120
    available_memory      = "256M"

    vpc_connector                 = google_vpc_access_connector.rotation.id
    vpc_connector_egress_settings = "PRIVATE_RANGES_ONLY"

    environment_variables = {
      PROJECT_ID           = var.project_id
      CLOUD_SQL_INSTANCE   = var.cloud_sql_instance_name
      CLOUD_SQL_IP         = var.cloud_sql_private_ip
      SECRET_REPL_NAME     = local.secret_repl_name
      SECRET_APP_NAME      = local.secret_app_name
      SECRET_POSTGRES_NAME = local.secret_postgres_name
      RDS_ENDPOINT         = var.rds_endpoint
      AWS_REGION           = var.aws_region
    }

    secret_environment_variables {
      key        = "AWS_ACCESS_KEY_ID"
      project_id = var.project_id
      secret     = google_secret_manager_secret.aws_access_key_id.secret_id
      version    = "latest"
    }

    secret_environment_variables {
      key        = "AWS_SECRET_ACCESS_KEY"
      project_id = var.project_id
      secret     = google_secret_manager_secret.aws_secret_access_key.secret_id
      version    = "latest"
    }
  }
  labels = local.common_labels

  depends_on = [
    google_storage_bucket_object.fn_source,
    google_vpc_access_connector.rotation,
    google_project_iam_member.default_compute_cloudbuild_builder,
    google_service_account_iam_member.tfc_act_as_rotation_fn
  ]

}


# ─────────────────────────────────────────────────────────
# GCS — Cloud Functions 소스 코드 저장
# ─────────────────────────────────────────────────────────
resource "google_storage_bucket" "fn_source" {
  name                        = "${var.project_id}-fn-source"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = local.common_labels
}

data "archive_file" "fn_source" {
  type        = "zip"
  output_path = "${path.module}/rotation_fn_source.zip"
  source_dir  = "${path.module}/container"
}

resource "google_storage_bucket_object" "fn_source" {
  name   = "rotation_fn_${data.archive_file.fn_source.output_md5}.zip"
  bucket = google_storage_bucket.fn_source.name
  source = data.archive_file.fn_source.output_path
}


# ─────────────────────────────────────────────────────────
# Cloud Scheduler — 7일마다 로테이션 트리거
# ─────────────────────────────────────────────────────────
resource "google_service_account" "scheduler" {
  account_id   = "gcp-sa-rotation-scheduler"
  display_name = "Cloud SQL Rotation Scheduler SA"
  project      = var.project_id
}

resource "google_cloudfunctions2_function_iam_member" "scheduler_invoker" {
  project        = var.project_id
  location       = var.region
  cloud_function = google_cloudfunctions2_function.rotation.name
  role           = "roles/cloudfunctions.invoker"
  member         = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_run_service_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.rotation.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "rotation" {
  name        = local.sch_rotation_name
  description = "Cloud SQL 비밀번호 7일 자동 로테이션 — ISMS-P 2.5.4"
  schedule    = var.rotation_schedule_cron
  time_zone   = "Asia/Seoul"
  project     = var.project_id
  region      = var.region

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.rotation.service_config[0].uri

    oidc_token {
      service_account_email = google_service_account.scheduler.email
    }
  }
}
resource "google_project_iam_member" "default_compute_cloudbuild_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_service_account_iam_member" "tfc_act_as_rotation_fn" {
  service_account_id = google_service_account.rotation_fn.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.tfc_service_account_email}"
}

# ─────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────
output "rotation_function_uri" {
  value       = google_cloudfunctions2_function.rotation.service_config[0].uri
  description = "Cloud Functions 수동 호출 URI"
}
