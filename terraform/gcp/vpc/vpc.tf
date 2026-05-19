# ── VPC ──────────────────────────────────────────────────────────────────────
resource "google_compute_network" "main" {
  name                    = "gcp-vpc"
  auto_create_subnetworks = false
}

# ── 서브넷 ────────────────────────────────────────────────────────────────────
resource "google_compute_subnetwork" "db" {
  name                     = "gcp-subnet"
  ip_cidr_range            = "10.10.1.0/24"
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true
}

# ── Private Service Access (Cloud SQL Private IP 연결용) ──────────────────────
resource "google_compute_global_address" "psa_range" {
  name          = "gcp-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]

  depends_on = [google_project_service.servicenetworking]
}

# ── 방화벽 ────────────────────────────────────────────────────────────────────
# DR 앱 → Cloud SQL 5432 허용 (VPC 내부만)
resource "google_compute_firewall" "allow_sql_internal" {
  name    = "gcp-fw-1"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  source_ranges = ["10.10.0.0/16"]
  target_tags   = ["cloud-sql-client"]
}

# pglogical: RDS → Cloud SQL 복제 수신 허용
resource "google_compute_firewall" "allow_pglogical_from_rds" {
  name    = "gcp-fw-2"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  source_ranges = [var.aws_vpc_cidr]
  target_tags   = ["cloud-sql-client"]
}

# 그 외 외부 접근 전체 차단
resource "google_compute_firewall" "deny_all_ingress" {
  name     = "gcp-fw-3"
  network  = google_compute_network.main.name
  priority = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
}
