resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dns" {
  service            = "dns.googleapis.com"
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
  app_name          = "gcp-dr-reservation"
  app_port          = 8000
  allowed_origins   = length(var.allowed_origins) > 0 ? join(",", var.allowed_origins) : "http://${trimsuffix(var.dns_record_name, ".")}"
  gcp_dns_rrdatas   = [google_compute_global_address.dr_lb.address]
  aws_dns_rrdatas   = join(",", var.aws_dns_rrdatas)
  gcp_dns_rrdatas_s = join(",", local.gcp_dns_rrdatas)
}

resource "google_storage_bucket" "artifact" {
  name                        = "${var.project_id}-dr-app-artifacts"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  depends_on = [google_project_service.storage]
}

resource "google_storage_bucket_object" "dr_app" {
  name   = "dr-lite-${data.archive_file.dr_app.output_md5}.zip"
  bucket = google_storage_bucket.artifact.name
  source = data.archive_file.dr_app.output_path
}

resource "google_compute_router" "dr_nat" {
  name    = "gcp-dr-router"
  network = data.google_compute_network.main.id
  region  = var.region
}

resource "google_compute_router_nat" "dr_nat" {
  name                               = "gcp-dr-nat"
  router                             = google_compute_router.dr_nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = data.google_compute_subnetwork.main.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

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

resource "google_service_account" "app" {
  account_id   = "gcp-dr-app-sa"
  display_name = "GCP DR reservation app"
}

resource "google_service_account" "monitor" {
  account_id   = "gcp-dr-monitor-sa"
  display_name = "GCP DR failover monitor"
}

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

resource "google_storage_bucket_iam_member" "app_artifact_reader" {
  bucket = google_storage_bucket.artifact.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.app.email}"
}

resource "google_project_iam_custom_role" "dr_monitor" {
  role_id     = "gcpDrFailoverMonitor"
  title       = "GCP DR Failover Monitor"
  description = "Least-privilege role for DR MIG resize and Cloud DNS record switching"
  permissions = [
    "compute.instanceGroupManagers.get",
    "compute.instanceGroupManagers.update",
    "compute.instanceGroups.get",
    "dns.changes.create",
    "dns.changes.get",
    "dns.managedZones.get",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update",
  ]
}

resource "google_project_iam_member" "monitor_failover_role" {
  project = var.project_id
  role    = google_project_iam_custom_role.dr_monitor.name
  member  = "serviceAccount:${google_service_account.monitor.email}"
}

resource "google_service_account_iam_member" "monitor_can_use_app_sa" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.monitor.email}"
}

resource "google_project_iam_member" "app_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.app.email}"
}

resource "google_project_iam_member" "monitor_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.monitor.email}"
}

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
  target_tags   = ["dr-app", "dr-monitor"]
}

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
      artifact_bucket         = google_storage_bucket.artifact.name
      artifact_object         = google_storage_bucket_object.dr_app.name
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

resource "google_compute_global_address" "dr_lb" {
  name = "gcp-dr-reservation-lb-ip"
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
  name    = "gcp-dr-reservation-http-proxy"
  url_map = google_compute_url_map.dr_app.id
}

resource "google_compute_global_forwarding_rule" "dr_app" {
  name                  = "gcp-dr-reservation-http"
  ip_address            = google_compute_global_address.dr_lb.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.dr_app.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_compute_instance" "monitor" {
  name         = "gcp-dr-monitor-01"
  machine_type = var.monitor_machine_type
  zone         = var.zone
  tags         = ["dr-monitor"]

  boot_disk {
    initialize_params {
      image = var.dr_source_image
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = data.google_compute_network.main.id
    subnetwork = data.google_compute_subnetwork.main.id
  }

  service_account {
    email  = google_service_account.monitor.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("${path.module}/scripts/startup-monitor.sh.tftpl", {
      project_id          = var.project_id
      zone                = var.zone
      mig_name            = google_compute_instance_group_manager.dr_app.name
      aws_healthcheck_url = var.aws_healthcheck_url
      interval_seconds    = var.healthcheck_interval_seconds
      failure_threshold   = var.failure_threshold
      recovery_threshold  = var.recovery_threshold
      dns_managed_zone    = var.dns_managed_zone
      dns_record_name     = var.dns_record_name
      dns_record_type     = var.dns_record_type
      dns_ttl             = var.dns_ttl
      aws_dns_rrdatas     = local.aws_dns_rrdatas
      gcp_dns_rrdatas     = local.gcp_dns_rrdatas_s
      failover_mode       = var.failover_mode
      enable_ops_agent    = var.enable_ops_agent
    })
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }
}
