#!/bin/bash
set -e

# ── ECS 클러스터 등록 ────────────────────────────────────
mkdir -p /etc/ecs
echo "ECS_CLUSTER=${cluster_name}" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE=true" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true" >> /etc/ecs/ecs.config
echo 'ECS_AVAILABLE_LOGGING_DRIVERS=["json-file","awslogs"]' >> /etc/ecs/ecs.config  # 추가

# 260601 박경수 ECS agent 자동시작 일시 중지 (Wazuh 설치 완료 후 수동 시작)
systemctl stop ecs || true

%{ if wazuh_server_ip != "" }
# ── Wazuh 에이전트 설치 ──────────────────────────────────
rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
cat > /etc/yum.repos.d/wazuh.repo << 'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF

WAZUH_MANAGER="${wazuh_server_ip}" \
WAZUH_AGENT_GROUP="ecs-ec2" \
  dnf install -y wazuh-agent-4.14.5-1

sed -i "s/^enabled=1/enabled=0/" /etc/yum.repos.d/wazuh.repo

cat > /var/ossec/etc/ossec.conf << 'OSSEC_EOF'
<ossec_config>
  <client>
    <server>
      <address>${wazuh_server_ip}</address>
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
      <manager_address>${wazuh_server_ip}</manager_address>
      <port>1515</port>
      <agent_name>ecs-ec2-AGENT_IP_PLACEHOLDER</agent_name>
      <groups>ecs-ec2</groups>
    </enrollment>
  </client>
</ossec_config>
OSSEC_EOF

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AGENT_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4 | tr '.' '-')
sed -i "s|AGENT_IP_PLACEHOLDER|$AGENT_IP|" /var/ossec/etc/ossec.conf
usermod -aG docker wazuh 2>/dev/null || true
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent || true
%{ endif }


# ── Grafana Alloy 설치 — AL2023 RPM 방식 ─────────────────
# 공식문서: https://grafana.com/docs/alloy/latest/set-up/install/linux/
curl -fsSL https://rpm.grafana.com/gpg.key | rpm --import -

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

cat > /etc/alloy/config.alloy << ALLOYEOF
prometheus.exporter.unix "local" {
  include_exporter_metrics = true
}
discovery.relabel "local" {
  targets = prometheus.exporter.unix.local.targets
  rule {
    target_label = "instance"
    replacement  = "ecs-ec2-$PRIVATE_IP"
  }
}
prometheus.scrape "local" {
  targets         = discovery.relabel.local.output
  forward_to      = [prometheus.remote_write.prometheus.receiver]
  scrape_interval = "15s"
}
prometheus.remote_write "prometheus" {
  endpoint {
    url = "http://${monitoring_ip}:9090/api/v1/write"
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
systemctl start alloy || true

# 260601 박경수  Wazuh 안정화 대기 후 ECS agent 시작

# sleep 30
# systemctl start ecs


# Wazuh agent active 상태 대기 (최대 120초)
# Wazuh agent가 120초 내에 활성화되지 않더라도 ECS는 시작하도록 함 (모니터링은 되지만 보안 이벤트는 누락될 수 있음)
# 30초는 불안해서 120초로 늘림 
# agent가 활성화되면 ECS를 시작하도록 변경 - 260603 김강환
echo "Waiting for wazuh-agent to become active..."
for i in $(seq 1 24); do
  if systemctl is-active --quiet wazuh-agent; then
    echo "Wazuh agent is active after $((i*5))s, starting ECS..."
    break
  fi
  if [ $i -eq 24 ]; then
    echo "Wazuh agent did not start in 120s, starting ECS anyway..."
  fi
  sleep 5
done

systemctl start ecs