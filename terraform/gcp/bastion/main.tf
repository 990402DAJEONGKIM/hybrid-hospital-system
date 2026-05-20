##############################################################
# main.tf
# GCP 베스천 호스트
#
# ISMS-P 준수:
#   - IAP(Identity-Aware Proxy) SSH 접속 (공인 IP 불필요)
#   - 외부 SSH 포트 직접 오픈 없음
#   - 최소 권한 서비스 계정
##############################################################

# ── 기존 리소스 참조 ─────────────────────────────────────────

data "google_compute_network" "main" {
  name = var.network
}

data "google_compute_subnetwork" "main" {
  name   = var.subnet
  region = var.region
}

# ── IAP API 활성화 ────────────────────────────────────────────

resource "google_project_service" "iap" {
  service            = "iap.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

# ── 베스천 전용 서비스 계정 (최소 권한) ──────────────────────

resource "google_service_account" "bastion" {
  account_id   = "gcp-bastion-sa"
  display_name = "GCP Bastion Service Account"
}

# Cloud SQL 접속 권한만 부여
resource "google_project_iam_member" "bastion_sql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.bastion.email}"
}

# ── 방화벽 — IAP SSH 허용 ─────────────────────────────────────
# IAP 터널 IP 대역만 허용 (35.235.240.0/20)
# 공인 IP에서 직접 SSH 불가

resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "gcp-fw-allow-iap-ssh"
  network = data.google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP 터널 IP 대역 (GCP 고정값)
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["gcp-bastion"]

  description = "Allow IAP SSH to bastion - ISMS-P compliant"
}

# ── 베스천 인스턴스 ───────────────────────────────────────────

resource "google_compute_instance" "bastion" {
  count        = var.bastion_count
  name         = "gcp-bastion-01"
  machine_type = "e2-micro"
  zone         = var.zone

  tags = ["gcp-bastion", "cloud-sql-client"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = data.google_compute_network.main.id
    subnetwork = data.google_compute_subnetwork.main.id
    # 공인 IP 없음 — IAP로만 접속
  }

  service_account {
    email  = google_service_account.bastion.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"  # OS Login으로 SSH 키 중앙 관리
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = {
    environment = "dev"
    managed-by  = "terraform"
    team        = "k2p"
  }
}
