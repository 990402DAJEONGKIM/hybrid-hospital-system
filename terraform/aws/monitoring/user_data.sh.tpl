#!/bin/bash
# Prometheus + Grafana EC2 초기화 스크립트
# 공식문서:
#   Prometheus: https://prometheus.io/docs/prometheus/latest/installation/
#   Grafana: https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/
set -e

# ── 기본 패키지 ──────────────────────────────────────────
apt-get update -y
apt-get install -y wget curl apt-transport-https software-properties-common gpg
apt-get install -y unzip 


# ── AWS CLI v2 설치 (AWS 공식문서 기준) ──────────────────
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# ── Prometheus 설치 (공식 바이너리) ──────────────────────
PROMETHEUS_VERSION="2.51.2"

useradd --no-create-home --shell /bin/false prometheus

mkdir -p /etc/prometheus /var/lib/prometheus

wget -q "https://github.com/prometheus/prometheus/releases/download/v$${PROMETHEUS_VERSION}/prometheus-$${PROMETHEUS_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/prometheus.tar.gz

tar -xzf /tmp/prometheus.tar.gz -C /tmp/
cp /tmp/prometheus-$${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
cp /tmp/prometheus-$${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
cp -r /tmp/prometheus-$${PROMETHEUS_VERSION}.linux-amd64/consoles /etc/prometheus/
cp -r /tmp/prometheus-$${PROMETHEUS_VERSION}.linux-amd64/console_libraries /etc/prometheus/

chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool

rm -rf /tmp/prometheus*

# ── Prometheus 설정 파일 ─────────────────────────────────
cat > /etc/prometheus/prometheus.yml <<'PROMEOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # Prometheus 자체 메트릭
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # ECS EC2 node exporter — EC2 Service Discovery (ASG 자동 탐지)
  - job_name: 'ecs-ec2'
    ec2_sd_configs:
      - region: ${aws_region}
        filters:
          - name: "tag:aws:ecs:cluster-name"
            values: ["aws-ecs-cluster-01"]
    relabel_configs:
      - source_labels: [__meta_ec2_private_ip]
        target_label: __address__
        replacement: '$1:9100'
      - source_labels: [__meta_ec2_tag_Name]
        target_label: instance

  # 온프레미스 서버
  - job_name: 'onprem'
    static_configs:
      - targets: ['172.30.1.76:9100']
        labels:
          instance: 'onprem-mspserver'

  # Wazuh Manager
  - job_name: 'wazuh-manager'
    static_configs:
      - targets: ['${wazuh_manager_ip}:9100']
        labels:
          instance: 'wazuh-manager-01'

  # Wazuh Indexer
  - job_name: 'wazuh-indexer'
    static_configs:
      - targets: ['${wazuh_indexer_ip}:9100']
        labels:
          instance: 'wazuh-indexer-01'
PROMEOF

chown prometheus:prometheus /etc/prometheus/prometheus.yml

# ── Prometheus systemd 서비스 ─────────────────────────────
cat > /etc/systemd/system/prometheus.service <<'SVCEOF'
[Unit]
Description=Prometheus Monitoring
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=15d \
  --web.listen-address=127.0.0.1:9090 \
  --web.enable-lifecycle
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# Prometheus는 127.0.0.1에서만 리슨 (외부 직접 접근 차단)

# ── Grafana 설치 (공식 APT 레포지토리) ───────────────────
mkdir -p /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
chmod 644 /etc/apt/keyrings/grafana.asc

echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
  | tee /etc/apt/sources.list.d/grafana.list

apt-get update -y
apt-get install -y grafana


# ── Secrets Manager에서 Grafana 비밀번호 가져오기 ─────────
GRAFANA_ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "aws-grafana-admin-password" \
  --region ${aws_region} \
  --query SecretString \
  --output text)

# ── Grafana 설정 ─────────────────────────────────────────
cat > /etc/grafana/grafana.ini <<GRAFANAEOF
[server]
http_port = 3000
root_url = https://grafana.${base_domain}

[security]
admin_user = admin
admin_password = $GRAFANA_ADMIN_PASSWORD
disable_gravatar = true

[auth.anonymous]
enabled = false

[analytics]
reporting_enabled = false
check_for_updates = false

[log]
mode = console
level = warn
GRAFANAEOF

# ── 서비스 활성화 및 시작 ─────────────────────────────────
systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus

systemctl enable grafana-server
systemctl start grafana-server