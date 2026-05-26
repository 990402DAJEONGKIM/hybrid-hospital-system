#!/bin/bash
set -e

# ── rsyslog 설치 (AL2023 기본 미포함) ───────────────────
dnf install -y rsyslog
systemctl enable rsyslog --now

# ── ECS 클러스터 등록 ────────────────────────────────────
echo "ECS_CLUSTER=${cluster_name}" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE=true" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true" >> /etc/ecs/ecs.config

%{ if wazuh_server_ip != "" }
# ── Wazuh 에이전트 설치 및 등록 ─────────────────────────
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
  yum install -y wazuh-agent

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent
%{ endif }
