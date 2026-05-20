##############################################################
# main.tf
# GCP 베스천 호스트
#
# ISMS-P 준수:
#   - IAP(Identity-Aware Proxy) SSH 접속 (공인 IP 불필요)
#   - 외부 SSH 포트 직접 오픈 없음
#   - 기존 서비스 계정 재사용
##############################################################

# ── 기존 리소스 참조 ─────────────────────────────────────────

data "google_compute_network" "main" {
  name = var.network
}

data "google_compute_subnetwork" "main" {
  name   = var.subnet
  region = var.region
}

data "google_service_account" "bastion" {
  account_id = "tc-st1-account"
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
    email  = data.google_service_account.bastion.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
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

# ── Cloud NAT (베스천 인터넷 접근용) ─────────────────────────

resource "google_compute_router" "main" {
  name    = "gcp-router"
  network = data.google_compute_network.main.id
  region  = var.region
}

resource "google_compute_router_nat" "main" {
  name                               = "gcp-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
