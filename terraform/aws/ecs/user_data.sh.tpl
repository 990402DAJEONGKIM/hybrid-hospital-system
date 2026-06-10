#!/bin/bash
set -e

# ── ECS 클러스터 등록 ────────────────────────────────────
# AWS 공식문서: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-agent-install.html
# "starting Amazon ECS or Docker via Amazon EC2 user data may cause a deadlock"
# ecs.service는 After=cloud-final.service로 묶여있어 cloud-init 도중 start/stop 호출 시 SIGTERM 발생
# 해결: --no-block 옵션으로 cloud-final 종료 대기 없이 systemd에 시작 요청만 등록
mkdir -p /etc/ecs
echo "ECS_CLUSTER=${cluster_name}" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE=true" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true" >> /etc/ecs/ecs.config
echo 'ECS_AVAILABLE_LOGGING_DRIVERS=["json-file","awslogs"]' >> /etc/ecs/ecs.config

# 260605 김강환 - ECS 자동시작 차단 (Wazuh agent 설치 완료 후 enable + --no-block start)
# 기존 `systemctl stop ecs || true`는 ecs.service After=cloud-final 의존성과 충돌해
# systemd가 cloud-init에 SIGTERM을 보내고 userdata가 13초 만에 죽었음
systemctl disable ecs

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

# Wazuh agent도 --no-block로 시작 (cloud-final 의존성 회피)
systemctl daemon-reload
systemctl enable --now --no-block wazuh-agent
%{ endif }

# ── Grafana Alloy 설치 ─────────────────────────────────
curl -s -o /tmp/grafana-gpg.key https://rpm.grafana.com/gpg.key
rpm --import /tmp/grafana-gpg.key
rm -f /tmp/grafana-gpg.key

cat > /etc/yum.repos.d/grafana.repo << 'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

dnf install -y alloy

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

# Alloy도 --no-block로 시작
systemctl enable --now --no-block alloy


# ── Vector 설치 (docker 로그 → S3 원본 보존) - 260608 김강환 ──
bash -c "$(curl -L https://setup.vector.dev)"
dnf install -y vector
mkdir -p /etc/vector

# vector.toml 설정 전에 추가 - 260609 김강환
touch /var/log/ecs-fastapi-audit.log
chown vector:vector /var/log/ecs-fastapi-audit.log
chmod 644 /var/log/ecs-fastapi-audit.log

cat > /etc/vector/vector.toml << 'VECTOREOF'
data_dir = "/var/lib/vector"

# docker 컨테이너 로그 읽기
[sources.docker_logs]
type = "docker_logs"


# fastapi_audit만 필터
[transforms.fastapi_only]
type = "filter"
inputs = ["docker_logs"]
condition = 'contains(string!(.message), "fastapi_audit")'

# EC2 IP 메타데이터 추가 (어느 EC2인지 구분)
[transforms.add_metadata]
type = "remap"
inputs = ["fastapi_only"]
source = '''
  .host = get_env_var!("PRIVATE_IP")
  . |= object!(parse_json!(.message))
'''

# S3 원본 저장
[sinks.s3_ecs]
type = "aws_s3"
inputs = ["add_metadata"]
bucket = "${s3_bucket}"
region = "${aws_region}"
key_prefix = "ecs/%Y/%m/%d/"
compression = "gzip"

[sinks.s3_ecs.encoding]
codec = "text"

[sinks.s3_ecs.batch]
timeout_secs = 300

[sinks.s3_ecs.buffer]
type = "memory"
max_events = 1000
when_full = "drop_newest"


[sinks.file_wazuh]
type = "file"
inputs = ["add_metadata"]
path = "/var/log/ecs-fastapi-audit.log"

[sinks.file_wazuh.encoding]
codec = "json"


VECTOREOF

# PRIVATE_IP 환경변수 설정
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

# systemd override로 환경변수 주입
mkdir -p /etc/systemd/system/vector.service.d
cat > /etc/systemd/system/vector.service.d/env.conf << EOF
[Service]
Environment="PRIVATE_IP=$PRIVATE_IP"
EOF
usermod -aG docker vector
echo 'VECTOR_CONFIG=/etc/vector/vector.toml' >> /etc/default/vector
systemctl daemon-reload
systemctl enable --now --no-block vector || true



# ── ECS agent 시작 (Wazuh/Alloy 설치 완료 후) ───────────
# AWS 공식 권장: --no-block로 cloud-init 데드락 회피
# enable 후 --now가 즉시 시작을 요청하지만 --no-block가 cloud-final 완료를 기다리지 않음
systemctl enable --now --no-block ecs