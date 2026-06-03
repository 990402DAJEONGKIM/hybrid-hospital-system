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
#   - 비밀번호 디스크 저장 금지 (실행 시 Secret Manager에서 동적 조회)
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


data "terraform_remote_state" "monitoring" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-monitoring" }
  }
}

# ── Cloud SQL 감사 로그 → Cloud Logging 활성화 ───────────────
# Cloud SQL 접근 로그(접속/쿼리)를 Cloud Logging으로 내보내기
# audit collector가 이 로그를 polling하여 cloudsql_audit_logs에 저장

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
# audit collector가 Cloud Logging을 읽기 위한 권한

resource "google_project_iam_member" "proxy_logging_viewer" {
  project = var.project_id
  role    = "roles/logging.viewer"
  member  = "serviceAccount:${data.google_service_account.proxy.email}"
}

# ── audit collector 스크립트 → GCS 업로드 ────────────────────
# startup script에서 gsutil cp로 다운로드하여 설치
# 버킷은 TC-gcp-dr에서 이미 생성된 gcp-project-496802-dr-app-artifacts 사용

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

  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    apt-get update -y
    apt-get install -y haproxy wget python3-pip

    # PostgreSQL 17 클라이언트 설치
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | tee /etc/apt/trusted.gpg.d/pgdg.asc
    apt-get update -y
    apt-get install -y postgresql-client-17

    # ── HAProxy 설정 ─────────────────────────────────────────
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

    # ── Cloud SQL Audit Collector 설치 ───────────────────────
    # ISMS-P 2.9.1: 비밀번호를 디스크에 저장하지 않고
    # 실행 시마다 Secret Manager에서 동적으로 조회
    pip3 install --quiet --break-system-packages google-cloud-logging psycopg2-binary

    mkdir -p /opt/audit-collector

    # Cloud SQL IP만 환경변수 파일에 저장 (비밀번호 제외)
    CLOUD_SQL_IP=$(gcloud sql instances describe ${var.cloud_sql_instance} \
        --project=${var.project_id} \
        --format="value(ipAddresses[0].ipAddress)" 2>/dev/null || echo "")

    cat > /opt/audit-collector/.env << ENV
CLOUD_SQL_IP=$CLOUD_SQL_IP
CLOUD_SQL_APP_USER=hospital_app
GCP_PROJECT=${var.project_id}
ENV
    chmod 600 /opt/audit-collector/.env

    # GCS에서 collector 스크립트 다운로드
    gsutil cp gs://${var.project_id}-dr-app-artifacts/cloudsql_audit_collector.py \
        /opt/audit-collector/cloudsql_audit_collector.py
    chmod +x /opt/audit-collector/cloudsql_audit_collector.py

    # wrapper: 실행 시마다 Secret Manager에서 비밀번호 동적 조회 (디스크 저장 금지)
    cat > /opt/audit-collector/run.sh << 'RUNEOF'
#!/bin/bash
set -a
source /opt/audit-collector/.env
set +a

# 비밀번호는 실행 시마다 Secret Manager에서 동적 조회 (ISMS-P 2.9.1)
CLOUD_SQL_APP_PASS=$(gcloud secrets versions access latest \
    --secret=gcp-cloud-sql-app-password \
    --project="$GCP_PROJECT" 2>/dev/null)

if [ -z "$CLOUD_SQL_APP_PASS" ]; then
    echo "[ERROR] Secret Manager에서 비밀번호 조회 실패" >&2
    exit 1
fi

export CLOUD_SQL_APP_PASS
exec /usr/bin/python3 /opt/audit-collector/cloudsql_audit_collector.py
RUNEOF
    chmod 700 /opt/audit-collector/run.sh

    # 로그 파일
    touch /var/log/audit-collector.log
    chmod 666 /var/log/audit-collector.log

    # cron 등록 (1분 주기)
    (crontab -l 2>/dev/null | grep -v audit-collector; \
     echo "* * * * * /opt/audit-collector/run.sh >> /var/log/audit-collector-info.log 2>&1") \
    | crontab -

    # ── DR Failover 모니터 설치 ──────────────────────────────
    DR_BUCKET="${var.project_id}-dr-app-artifacts"
    DR_SCRIPT_URI="gs://$DR_BUCKET/dr-monitor-install.sh"

    if gsutil -q stat "$DR_SCRIPT_URI" 2>/dev/null; then
      gsutil cp "$DR_SCRIPT_URI" /tmp/dr-monitor-install.sh
      chmod +x /tmp/dr-monitor-install.sh
      bash /tmp/dr-monitor-install.sh
    else
      echo "DR monitor script not found in GCS, skipping." | logger -t dr-monitor-setup
    fi

    # ── Wazuh Agent 설치 ─────────────────────────────────────
    # ISMS-P 2.9.1: 보안 이벤트 로그 수집
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH \
      | gpg --no-default-keyring \
            --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
            --import
    chmod 644 /usr/share/keyrings/wazuh.gpg

    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
https://packages.wazuh.com/4.x/apt/ stable main" \
      | tee /etc/apt/sources.list.d/wazuh.list

    apt-get update -y
    apt-get install -y wazuh-agent=4.14.5-*

    cat > /var/ossec/etc/ossec.conf << 'WAZUH_EOF'
<ossec_config>
  <client>
    <server>
      <address>${var.wazuh_manager_ip}</address>
      <port>1514</port>
      <protocol>tcp</protocol>
      <max_retries>100</max_retries>
      <retry_interval>15</retry_interval>
    </server>
    <notify_time>10</notify_time>
    <time-reconnect>60</time-reconnect>
    <auto_restart>yes</auto_restart>
    <enrollment>
      <enabled>yes</enabled>
      <manager_address>${var.wazuh_manager_ip}</manager_address>
      <port>1515</port>
      <agent_name>gcp-rds-proxy-01</agent_name>
      <groups>gcp-proxy</groups>
    </enrollment>
  </client>
</ossec_config>
WAZUH_EOF

    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent

    sed -i "s/^deb/#deb/" /etc/apt/sources.list.d/wazuh.list
    apt-get update -y

# ── Grafana Alloy 설치 — Prometheus 메트릭 push 방식 ─────
    # 공식문서: https://grafana.com/docs/alloy/latest/set-up/install/linux/
    mkdir -p /etc/apt/keyrings
    wget -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
    chmod 644 /etc/apt/keyrings/grafana.asc
    echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
      | tee /etc/apt/sources.list.d/grafana.list
    apt-get update -y
    apt-get install -y alloy

    cat > /etc/alloy/config.alloy << ALLOYEOF
prometheus.exporter.unix "local" {
  include_exporter_metrics = true
}
prometheus.scrape "local" {
  targets         = prometheus.exporter.unix.local.targets
  forward_to      = [prometheus.remote_write.prometheus.receiver]
  scrape_interval = "15s"
}
prometheus.remote_write "prometheus" {
  endpoint {
    url = "http://${data.terraform_remote_state.monitoring.outputs.monitoring_private_ip}:9090/api/v1/write"
  }
  wal {
    truncate_frequency = "2h"
    min_keepalive_time = "5m"
    max_keepalive_time = "8h"
  }
}
ALLOYEOF

    systemctl daemon-reload
    systemctl enable alloy
    systemctl start alloy






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

  # audit_collector 스크립트가 GCS에 올라간 뒤 VM이 생성되도록
  depends_on = [google_storage_bucket_object.audit_collector]
}
