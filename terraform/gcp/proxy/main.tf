##############################################################
# main.tf
# GCP HAProxy - AWS RDS TCP 포워딩
#
# 구조:
#   Cloud SQL → 10.10.1.37:5433 (MIG proxy, Static IP 고정)
#              → 10.0.21.124:5432 (AWS RDS)
#
# ISMS-P 준수:
#   - 공인 IP 없음 (IAP로만 관리 접근)
#   - Cloud SQL → proxy 5433만 허용
#   - proxy → RDS 5432만 허용
#   - 비밀번호 디스크 저장 금지 (실행 시 Secret Manager에서 동적 조회)
#   - MIG auto-healing으로 가용성 확보 (ISMS-P 2.12.1)
#   - 커스텀 이미지 기반 복구 (ISMS-P 2.9.3)
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

# ── 예약된 Static Internal IP 참조 ───────────────────────────
data "google_compute_address" "proxy_internal" {
  name   = "gcp-rds-proxy-internal-ip"
  region = var.region
}

# ── 최신 커스텀 이미지 참조 (family 기반) ─────────────────────
data "google_compute_image" "proxy_image" {
  family  = "gcp-rds-proxy"
  project = var.project_id
}


# ── CloudSQL 메트릭 수집용 IAM 권한 ─────────────────────────
# Alloy prometheus.exporter.gcp가 GCP Cloud Monitoring API 호출 시 필요 - 260604 김강환

resource "google_project_iam_member" "proxy-monitoring-viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${data.google_service_account.proxy.email}"
}


data "terraform_remote_state" "monitoring" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-monitoring" }
  }
}

# ── Cloud SQL 감사 로그 → Cloud Logging 활성화 ───────────────
resource "google_project_iam_audit_config" "cloud_sql_audit" {
  project = var.project_id
  service = "cloudsql.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }

  audit_log_config {
    log_type = "ADMIN_READ"
  }
}

# ── 서비스 계정 IAM 권한 ─────────────────────────────────────
resource "google_project_iam_member" "proxy_logging_viewer" {
  project = var.project_id
  role    = "roles/logging.viewer"
  member  = "serviceAccount:${data.google_service_account.proxy.email}"
}

# ── audit collector 스크립트 → GCS 업로드 ────────────────────
resource "google_storage_bucket_object" "audit_collector" {
  name   = "cloudsql_audit_collector.py"
  bucket = "${var.project_id}-dr-app-artifacts"
  source = "${path.module}/scripts/cloudsql_audit_collector.py"
}

# ── 방화벽 — Cloud SQL PSA 대역 → proxy 5433 허용 ────────────

resource "google_compute_firewall" "allow_cloud_sql_to_proxy" {
  name    = "gcp-fw-allow-cloudsql-proxy"
  network = data.google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["5433"]
  }

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

# ── 헬스체크 — HAProxy TCP 5433 ───────────────────────────────
# ISMS-P 2.12.1: 자동 장애감지 및 복구

resource "google_compute_health_check" "proxy_tcp" {
  name    = "gcp-proxy-haproxy-health"
  project = var.project_id

  timeout_sec         = 5
  check_interval_sec  = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3 # 30초 무응답 시 unhealthy → auto-healing 트리거

  tcp_health_check {
    port = 5433
  }
}

# ── 인스턴스 템플릿 (커스텀 이미지 기반) ─────────────────────
# 이미지에 HAProxy, Wazuh, Alloy, audit-collector 등 모두 설치됨
# startup-script는 서비스 재시작만 수행

resource "google_compute_instance_template" "proxy" {
  name_prefix  = "gcp-rds-proxy-tpl-"
  machine_type = "e2-micro"
  region       = var.region
  project      = var.project_id

  tags = ["rds-proxy"]

  disk {
    source_image = data.google_compute_image.proxy_image.self_link
    auto_delete  = true
    boot         = true
    disk_size_gb = 10
    disk_type    = "pd-standard"
  }

  network_interface {
    network    = data.google_compute_network.main.id
    subnetwork = data.google_compute_subnetwork.main.id
    network_ip = data.google_compute_address.proxy_internal.address
    # 공인 IP 없음
  }

  service_account {
    email  = data.google_service_account.proxy.email
    scopes = ["cloud-platform"]
  }

  # 커스텀 이미지에 모든 서비스가 설치되어 있으므로
  # 재시작 시 서비스 기동만 보장
  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    set -e

    # HAProxy
    systemctl is-active haproxy || systemctl start haproxy

    # audit-collector cron (혹시 누락 시 재등록)
    if ! crontab -l 2>/dev/null | grep -q audit-collector; then
      (crontab -l 2>/dev/null; \
       echo "* * * * * /opt/audit-collector/run.sh >> /var/log/audit-collector-info.log 2>&1") \
      | crontab -
    fi

    # DR Failover 모니터
    SCRIPT_PATH="/opt/gcp-dr-failover.sh"
    if [ -f "$SCRIPT_PATH" ] && ! pgrep -f "$SCRIPT_PATH" > /dev/null; then
      nohup bash "$SCRIPT_PATH" >> /var/log/dr-failover.log 2>&1 &
    fi

    # Wazuh Agent
    systemctl is-active wazuh-agent || systemctl start wazuh-agent

    # Grafana Alloy
    systemctl is-active alloy || systemctl start alloy
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

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_storage_bucket_object.audit_collector]
}

# ── MIG — size=1, auto-healing 활성화 ────────────────────────
# ISMS-P 2.12.1: 자동 복구 (이미지 기반 2~3분 내 재구동)

resource "google_compute_instance_group_manager" "proxy" {
  name               = "gcp-rds-proxy-mig"
  base_instance_name = "gcp-rds-proxy"
  zone               = var.zone
  project            = var.project_id

  version {
    instance_template = google_compute_instance_template.proxy.id
  }

  target_size = var.proxy_count

  auto_healing_policies {
    health_check      = google_compute_health_check.proxy_tcp.id
    initial_delay_sec = 120 # 부팅 + 서비스 기동 여유시간
  }

  # 이미지 교체 시 무중단 롤링 업데이트
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1
  }
}
