resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

locals {
  app_name        = "gcp-dr-app"
  app_port        = 8000
  allowed_origins = length(var.allowed_origins) > 0 ? join(",", var.allowed_origins) : "https://mzclinic.cloud"
}

# ── GCS 아티팩트 버킷 ──────────────────────────────────────────────────────────

resource "google_storage_bucket" "artifact" {
  name                        = "${var.project_id}-dr-app-artifacts"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  depends_on = [google_project_service.storage]
}

resource "google_storage_bucket_object" "dr_app" {
  name   = "dr-app-${data.archive_file.dr_app.output_md5}.zip"
  bucket = google_storage_bucket.artifact.name
  source = data.archive_file.dr_app.output_path
}

# 모니터 설치 스크립트 GCS 업로드
# variables 변경 후 apply → gcp-rds-proxy-01 reset 으로 반영
resource "google_storage_bucket_object" "monitor_script" {
  name   = "dr-monitor-install.sh"
  bucket = google_storage_bucket.artifact.name
  content = templatefile("${path.module}/scripts/startup-monitor.sh.tftpl", {
    project_id              = var.project_id
    zone                    = var.zone
    mig_name                = google_compute_instance_group_manager.dr_app.name
    aws_healthcheck_url     = var.aws_healthcheck_url
    interval_seconds        = var.healthcheck_interval_seconds
    failure_threshold       = var.failure_threshold
    recovery_threshold      = var.recovery_threshold
    cf_api_token_secret     = var.cf_api_token_secret_name
    cf_zone_id_secret       = var.cf_zone_id_secret_name
    cf_record_name          = var.cf_record_name
    gcp_cname_target        = var.gcp_cname_target
    aws_record_content      = var.aws_record_content
    failover_mode           = var.failover_mode
    enable_ops_agent        = var.enable_ops_agent
  })
}

# ── Secret Manager ─────────────────────────────────────────────────────────────

resource "google_secret_manager_secret" "jwt_secret" {
  secret_id = var.jwt_secret_name
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "api_key" {
  secret_id = var.api_key_secret_name
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "slack_webhook" {
  secret_id = "gcp-dr-slack-webhook"
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

# Cloudflare 시크릿 — 프록시 VM 모니터 스크립트가 런타임에 읽음
resource "google_secret_manager_secret" "cf_api_token" {
  secret_id = var.cf_api_token_secret_name
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret" "cf_zone_id" {
  secret_id = var.cf_zone_id_secret_name
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

# ── Service Account ────────────────────────────────────────────────────────────

resource "google_service_account" "app" {
  account_id   = "gcp-dr-app-sa"
  display_name = "GCP DR staff app"
}

# ── IAM 바인딩 — DR 앱 SA ──────────────────────────────────────────────────────

resource "google_secret_manager_secret_iam_member" "app_db_password_access" {
  secret_id = var.db_password_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app.email}"
}

resource "google_secret_manager_secret_iam_member" "app_jwt_secret_access" {
  secret_id = google_secret_manager_secret.jwt_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app.email}"
}

resource "google_secret_manager_secret_iam_member" "app_api_key_access" {
  secret_id = google_secret_manager_secret.api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app.email}"
}

resource "google_project_iam_member" "app_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.app.email}"
}

resource "google_storage_bucket_iam_member" "app_artifact_reader" {
  bucket = google_storage_bucket.artifact.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.app.email}"
}

# ── IAM 바인딩 — 프록시 VM SA (모니터 스크립트) ────────────────────────────────

resource "google_secret_manager_secret_iam_member" "proxy_slack_webhook_access" {
  secret_id = google_secret_manager_secret.slack_webhook.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.proxy_service_account_email}"
}

resource "google_secret_manager_secret_iam_member" "proxy_cf_api_token_access" {
  secret_id = google_secret_manager_secret.cf_api_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.proxy_service_account_email}"
}

resource "google_secret_manager_secret_iam_member" "proxy_cf_zone_id_access" {
  secret_id = google_secret_manager_secret.cf_zone_id.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.proxy_service_account_email}"
}

resource "google_storage_bucket_iam_member" "proxy_artifact_reader" {
  bucket = google_storage_bucket.artifact.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.proxy_service_account_email}"
}

# 프록시 VM SA — MIG resize 전용 커스텀 역할
resource "google_project_iam_custom_role" "dr_monitor" {
  role_id     = "gcpDrFailoverMonitor"
  title       = "GCP DR Failover Monitor"
  description = "DR MIG resize 전용 최소 권한 역할 (DNS 전환은 Cloudflare API로 처리)"
  permissions = [
    "compute.instanceGroupManagers.get",
    "compute.instanceGroupManagers.update",
    "compute.instanceGroups.get",
  ]
}

resource "google_project_iam_member" "proxy_failover_role" {
  project = var.project_id
  role    = google_project_iam_custom_role.dr_monitor.name
  member  = "serviceAccount:${var.proxy_service_account_email}"
}

resource "google_service_account_iam_member" "proxy_can_use_app_sa" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.proxy_service_account_email}"
}

resource "google_project_iam_member" "proxy_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${var.proxy_service_account_email}"
}

# ── 방화벽 ─────────────────────────────────────────────────────────────────────

resource "google_compute_firewall" "allow_lb_to_dr_app" {
  name    = "gcp-fw-allow-lb-to-dr-app"
  network = data.google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["dr-app"]
}

resource "google_compute_firewall" "allow_iap_ssh_dr" {
  name    = "gcp-fw-allow-iap-ssh-dr"
  network = data.google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["dr-app"]
}

# ── MIG / Instance Template ────────────────────────────────────────────────────

resource "google_compute_instance_template" "dr_app" {
  name_prefix  = "gcp-dr-reservation-"
  machine_type = var.dr_machine_type
  tags         = ["dr-app", "cloud-sql-client"]

  disk {
    source_image = var.dr_source_image
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-standard"
  }

  network_interface {
    network    = data.google_compute_network.main.id
    subnetwork = data.google_compute_subnetwork.main.id
  }

  service_account {
    email  = google_service_account.app.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("${path.module}/scripts/startup-dr-app.sh.tftpl", {
      project_id              = var.project_id
      cloud_sql_ip            = data.google_sql_database_instance.main.private_ip_address
      database_name           = var.database_name
      database_user           = var.database_user
      db_password_secret_name = var.db_password_secret_name
      jwt_secret_name         = google_secret_manager_secret.jwt_secret.secret_id
      api_key_secret_name     = google_secret_manager_secret.api_key.secret_id
      allowed_origins         = local.allowed_origins
      enable_ops_agent        = var.enable_ops_agent
      app_port                = local.app_port
      cookie_secure           = var.cookie_secure
      artifact_bucket         = google_storage_bucket.artifact.name
      dr_app_object           = google_storage_bucket_object.dr_app.name
    })
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_instance_group_manager" "dr_app" {
  name               = "gcp-dr-reservation-mig"
  zone               = var.zone
  base_instance_name = "gcp-dr-reservation"
  target_size        = var.initial_dr_capacity

  version {
    instance_template = google_compute_instance_template.dr_app.id
  }

  named_port {
    name = "http"
    port = 80
  }
}

# ── Load Balancer ──────────────────────────────────────────────────────────────

resource "google_compute_global_address" "dr_lb" {
  name = "gcp-dr-app-lb-ip"
}

resource "google_compute_health_check" "dr_app" {
  name = "gcp-dr-reservation-hc"

  http_health_check {
    port         = 80
    request_path = "/health"
  }
}

resource "google_compute_backend_service" "dr_app" {
  name                  = "gcp-dr-reservation-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.dr_app.id]

  backend {
    group = google_compute_instance_group_manager.dr_app.instance_group
  }
}

resource "google_compute_url_map" "dr_app" {
  name            = "gcp-dr-reservation-urlmap"
  default_service = google_compute_backend_service.dr_app.id
}

resource "google_compute_target_http_proxy" "dr_app" {
  name    = "gcp-dr-staff-http-proxy"
  url_map = google_compute_url_map.dr_app.id
}

resource "google_compute_global_forwarding_rule" "dr_app" {
  name                  = "gcp-dr-staff-http"
  ip_address            = google_compute_global_address.dr_lb.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.dr_app.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# ── IAM — Terraform Cloud DR SA ────────────────────────────────────────────────

resource "google_service_account" "terraform_dr" {
  account_id   = "gcp-sa-dr-terraform"
  display_name = "Terraform Cloud DR SA"
  description  = "TC-gcp-dr 워크스페이스 전용 Terraform 실행 SA"
}

locals {
  terraform_dr_roles = [
    "roles/compute.admin",
    "roles/iam.roleAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountTokenCreator",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/storage.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/cloudsql.viewer",
    "roles/logging.admin",
  ]
}

resource "google_project_iam_member" "terraform_dr_roles" {
  for_each = toset(local.terraform_dr_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.terraform_dr.email}"
}

resource "google_service_account_iam_member" "terraform_dr_use_app_sa" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.terraform_dr.email}"
}

# ── WIF — Terraform Cloud ──────────────────────────────────────────────────────

resource "google_iam_workload_identity_pool" "terraform_cloud" {
  workload_identity_pool_id = "terraform-cloud-pool"
  display_name              = "terraform-cloud-pool"
  description               = "Terraform Cloud WIF Pool"
}

resource "google_iam_workload_identity_pool_provider" "terraform_cloud" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.terraform_cloud.workload_identity_pool_id
  workload_identity_pool_provider_id = "tfc-provider"
  display_name                       = "tfc-provider"

  oidc {
    issuer_uri = "https://app.terraform.io"
  }

  attribute_mapping = {
    "google.subject"                        = "assertion.sub"
    "attribute.aud"                         = "assertion.aud"
    "attribute.terraform_workspace_id"      = "assertion.terraform_workspace_id"
    "attribute.terraform_organization_name" = "assertion.terraform_organization_name"
  }

  attribute_condition = "assertion.sub.startsWith(\"organization:k2p\")"
}

resource "google_service_account_iam_member" "tfc_dr_workload_identity" {
  service_account_id = google_service_account.terraform_dr.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.terraform_cloud.name}/attribute.terraform_workspace_id/ws-3wAP7iDiNKH8UHrR"
}

resource "google_service_account_iam_member" "tfc_dr_token_creator" {
  service_account_id = google_service_account.terraform_dr.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.terraform_cloud.name}/attribute.terraform_workspace_id/ws-3wAP7iDiNKH8UHrR"
}

# ── WIF — GitHub Actions ───────────────────────────────────────────────────────

resource "google_service_account" "github_packer" {
  account_id   = "gcp-sa-github-packer"
  display_name = "GitHub Actions Packer SA"
  description  = "DR 앱 Custom Image 빌드 전용 SA"
}

locals {
  github_packer_roles = [
    "roles/compute.instanceAdmin.v1",
    "roles/iam.serviceAccountUser",
    "roles/iap.tunnelResourceAccessor",
    "roles/storage.objectViewer",
  ]
}

resource "google_project_iam_member" "github_packer_roles" {
  for_each = toset(local.github_packer_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.github_packer.email}"
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  description               = "GitHub Actions WIF Pool"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "github-provider"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository=='990402DAJEONGKIM/hybrid-hospital-system'"
}

resource "google_service_account_iam_member" "github_packer_workload_identity" {
  service_account_id = google_service_account.github_packer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/990402DAJEONGKIM/hybrid-hospital-system"
}

resource "google_service_account_iam_member" "github_packer_token_creator" {
  service_account_id = google_service_account.github_packer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/990402DAJEONGKIM/hybrid-hospital-system"
}

# ── Cloud Logging ──────────────────────────────────────────────────────────────

resource "google_logging_project_bucket_config" "default" {
  project        = var.project_id
  location       = "global"
  bucket_id      = "_Default"
  retention_days = 365
}
