##############################################################
# main.tf
# GCP HAProxy - AWS RDS TCP 포워딩
#
# 구조:
#   Cloud SQL → 10.10.1.x:5433 (이 VM)
#              → 10.0.21.124:5432 (AWS RDS)
#
# ISMS-P 준수:
#   - 공인 IP 없음 (IAP로만 관리 접근)
#   - Cloud SQL → proxy 5433만 허용
#   - proxy → RDS 5432만 허용
##############################################################

data "google_compute_network" "main" {
  name = var.network
}

data "google_compute_subnetwork" "main" {
  name   = var.subnet
  region = var.region
}

data "google_service_account" "proxy" {
  account_id = "tc-st1-account"
}

# ── 방화벽 — Cloud SQL PSA 대역 → proxy 5433 허용 ────────────

resource "google_compute_firewall" "allow_cloud_sql_to_proxy" {
  name    = "gcp-fw-allow-cloudsql-proxy"
  network = data.google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["5433"]
  }

  # Cloud SQL PSA 대역
  source_ranges = ["172.29.0.0/24"]
  target_tags   = ["rds-proxy"]

  description = "Allow Cloud SQL PSA to HAProxy (pglogical)"
}

# ── 방화벽 — IAP SSH 허용 ─────────────────────────────────────

resource "google_compute_firewall" "allow_iap_ssh_proxy" {
  name    = "gcp-fw-allow-iap-ssh-proxy"
  network = data.google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["rds-proxy"]

  description = "Allow IAP SSH to proxy - ISMS-P compliant"
}

# ── 프록시 인스턴스 ───────────────────────────────────────────

resource "google_compute_instance" "proxy" {
  count        = var.proxy_count
  name         = "gcp-rds-proxy-01"
  machine_type = "e2-micro"
  zone         = var.zone

  tags = ["rds-proxy"]

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
    # 공인 IP 없음
  }

  service_account {
    email  = data.google_service_account.proxy.email
    scopes = ["cloud-platform"]
  }

  # HAProxy + PostgreSQL 클라이언트 자동 설치 및 설정
  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    apt-get update -y
    apt-get install -y haproxy wget

    # PostgreSQL 17 클라이언트 설치 (pglogical_setup.sh에서 psql 사용)
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | tee /etc/apt/trusted.gpg.d/pgdg.asc
    apt-get update -y
    apt-get install -y postgresql-client-17

    cat > /etc/haproxy/haproxy.cfg << 'HAPROXY'
global
    log /dev/log local0
    maxconn 256

defaults
    log global
    mode tcp
    timeout connect 5s
    timeout client  10m
    timeout server  10m

frontend rds_proxy
    bind *:5433
    default_backend rds_backend

backend rds_backend
    server rds ${var.rds_ip}:${var.rds_port} check
HAPROXY

    systemctl restart haproxy
    systemctl enable haproxy

    # ── DR Failover 모니터 설치 ──────────────────────────────────
    # DR terraform apply 시 GCS에 업로드된 스크립트를 다운로드해서 설치합니다.
    # DR 변수 변경 후: terraform apply (TC-gcp-dr) → VM reset으로 반영
    DR_BUCKET="${var.project_id}-dr-app-artifacts"
    DR_SCRIPT_URI="gs://$DR_BUCKET/dr-monitor-install.sh"

    # GCS에 스크립트가 존재할 때만 설치 (DR terraform이 먼저 apply되지 않은 경우 skip)
    if gsutil -q stat "$DR_SCRIPT_URI" 2>/dev/null; then
      gsutil cp "$DR_SCRIPT_URI" /tmp/dr-monitor-install.sh
      chmod +x /tmp/dr-monitor-install.sh
      bash /tmp/dr-monitor-install.sh
    else
      echo "DR monitor script not found in GCS, skipping. Run TC-gcp-dr apply first." | logger -t dr-monitor-setup
    fi
  SCRIPT

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
    role        = "rds-proxy"
  }
}
