#!/bin/bash
# Prometheus + Alloy + Grafana EC2 초기화 스크립트
# 공식문서:
#   Prometheus: https://prometheus.io/docs/prometheus/latest/installation/
#   Grafana Alloy: https://grafana.com/docs/alloy/latest/set-up/install/linux/
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
PROMETHEUS_VERSION="2.53.5"

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
# Alloy push 방식으로 전환 — scrape 설정 불필요
# prometheus 자체 메트릭만 scrape
cat > /etc/prometheus/prometheus.yml <<'PROMEOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # Prometheus 자체 메트릭만 scrape
  # 나머지 서버는 Alloy가 push 방식으로 전송
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
PROMEOF

chown prometheus:prometheus /etc/prometheus/prometheus.yml

# ── Prometheus systemd 서비스 ─────────────────────────────
# --web.enable-remote-write-receiver: Alloy push 받기 위해 필수
# --web.listen-address=0.0.0.0:9090: Alloy가 push하려면 외부 접근 가능해야 함
# 공식문서: https://prometheus.io/docs/prometheus/2.55/feature_flags/
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
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle \
  --web.enable-remote-write-receiver
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# ── Grafana Alloy 설치 (공식 APT 레포지토리) ─────────────
# 공식문서: https://grafana.com/docs/alloy/latest/set-up/install/linux/
mkdir -p /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
chmod 644 /etc/apt/keyrings/grafana.asc

echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
  | tee /etc/apt/sources.list.d/grafana.list

apt-get update -y
apt-get install -y alloy grafana



# ── Alloy 설정 파일 ──────────────────────────────────────
# prometheus.exporter.unix: node exporter 내장 기능으로 시스템 메트릭 수집
# prometheus.remote_write: WAL 버퍼링 후 Prometheus로 push
# 공식문서: https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.unix/
cat > /etc/alloy/config.alloy <<'ALLOYEOF'
// ── monitoring EC2 자체 시스템 메트릭 수집 ───────────────
// node exporter 내장 — 별도 설치 불필요
prometheus.exporter.unix "local" {
  include_exporter_metrics = true
}
discovery.relabel "local" {
  targets = prometheus.exporter.unix.local.targets
  rule {
    target_label = "instance"
    replacement  = "monitoring"
  }
}
prometheus.scrape "local" {
  targets         = discovery.relabel.local.output
  forward_to      = [prometheus.remote_write.prometheus.receiver]
  scrape_interval = "15s"
}
prometheus.remote_write "prometheus" {
  endpoint {
    url = "http://localhost:9090/api/v1/write"
  }
  wal {
    truncate_frequency = "2h"
    min_keepalive_time = "5m"
    max_keepalive_time = "8h"
  }
}
ALLOYEOF


# ── Secrets Manager에서 Grafana 비밀번호 가져오기 ─────────
GRAFANA_ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "aws-grafana-admin-password" \
  --region ${aws_region} \
  --query SecretString \
  --output text)

# ── Secrets Manager에서 Slack webhook 가져오기 (TC 변수 평문 제거) ─────────
SLACK_WEBHOOK_URL=$(aws secretsmanager get-secret-value \
  --secret-id "aws-wazuh-slack-alarm-webhook" \
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
# #260609 박경수 — Grafana 13 iframe 허용 (allow_embedding deprecated)
content_security_policy = false


[auth.anonymous]
enabled = false

[analytics]
reporting_enabled = false
check_for_updates = false

[log]
mode = console
level = warn
GRAFANAEOF

# ── Grafana Provisioning — Data Sources ──────────────────
# EC2 재생성해도 자동으로 Data Source 설정
mkdir -p /etc/grafana/provisioning/datasources

# Prometheus Data Source — Alloy가 push한 메트릭 조회
cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: prometheus
    type: prometheus
    uid: prometheus
    url: http://localhost:9090
    isDefault: true
    editable: false
EOF

# ── Grafana Provisioning — Alerting ──────────────────────
mkdir -p /etc/grafana/provisioning/alerting

cat > /etc/grafana/provisioning/alerting/contactpoints.yaml <<EOF
apiVersion: 1
contactPoints:
  - orgId: 1
    name: slack-alerts
    receivers:
      - uid: slack-receiver
        type: slack
        settings:
          url: $SLACK_WEBHOOK_URL
          title: "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}"
          text: "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}"
EOF

cat > /etc/grafana/provisioning/alerting/policy.yaml <<'EOF'
apiVersion: 1
policies:
  - orgId: 1
    receiver: slack-alerts
    group_by: ['alertname', 'instance']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
EOF

cat > /etc/grafana/provisioning/alerting/rules.yaml <<'EOF'
apiVersion: 1
groups:
  - orgId: 1
    name: system-alerts
    folder: Alerts
    interval: 1m
    rules:
      - uid: cpu-high
        title: CPU Usage High
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: prometheus
            model:
              expr: 100 * (1 - avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              type: reduce
              expression: A
              reducer: last
              refId: B
          - refId: C
            datasourceUid: __expr__
            model:
              type: threshold
              expression: B
              conditions:
                - evaluator:
                    params: [70]
                    type: gt
              refId: C
        noDataState: NoData
        execErrState: Error
        for: 5m
        annotations:
          summary: "CPU {{ $labels.instance }} 사용률 높음"
        labels:
          severity: warning
        isPaused: false
      - uid: memory-high
        title: Memory Usage High
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: prometheus
            model:
              expr: 100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              type: reduce
              expression: A
              reducer: last
              refId: B
          - refId: C
            datasourceUid: __expr__
            model:
              type: threshold
              expression: B
              conditions:
                - evaluator:
                    params: [70]
                    type: gt
              refId: C
        noDataState: NoData
        execErrState: Error
        for: 5m
        annotations:
          summary: "Memory {{ $labels.instance }} 사용률 높음"
        labels:
          severity: warning
        isPaused: false
EOF



# CloudWatch Data Source — RDS/ALB/ECS AWS 인프라 메트릭
# IAM Role 기반 인증 (EC2 Instance Profile)
cat > /etc/grafana/provisioning/datasources/cloudwatch.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: CloudWatch
    type: cloudwatch
    access: proxy
    jsonData:
      authType: default
      defaultRegion: ap-south-2
    editable: false
EOF

# ── 서비스 활성화 및 시작 ─────────────────────────────────
systemctl daemon-reload

systemctl enable prometheus
systemctl start prometheus

# Alloy는 Prometheus 시작 후 실행 — remote write 연결 보장
systemctl enable alloy
systemctl start alloy

systemctl enable grafana-server
systemctl start grafana-server

# #260609 박경수 — Keycloak + nginx 설치 (S3에서 스크립트 받아 실행)
# user_data 16KB 제한으로 별도 분리
aws s3 cp s3://aws-k2p-storage-01/monitoring/keycloak_setup.sh /tmp/keycloak_setup.sh \
  --region ap-south-2
chmod +x /tmp/keycloak_setup.sh
bash /tmp/keycloak_setup.sh >> /var/log/keycloak_setup.log 2>&1
# #260609 박경수 end
