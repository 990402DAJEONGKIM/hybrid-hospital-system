#!/bin/bash
set -e

# ── ECS 클러스터 등록 ────────────────────────────────────
mkdir -p /etc/ecs
echo "ECS_CLUSTER=${cluster_name}" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE=true" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true" >> /etc/ecs/ecs.config

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
    </server>
    <server>
      <address>${wazuh_server_ip_secondary}</address>
      <port>1514</port>
      <protocol>tcp</protocol>
    </server>
    <notify_time>10</notify_time>
    <time-reconnect>60</time-reconnect>
    <auto_restart>yes</auto_restart>
    <enrollment>
      <enabled>yes</enabled>
      <manager_address>${wazuh_server_ip}</manager_address>
      <port>1515</port>
      <groups>ecs-ec2</groups>
    </enrollment>
  </client>
</ossec_config>
OSSEC_EOF

AGENT_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 | tr '.' '-')
sed -i "s|<client>|<client>\n    <agent_name>ecs-ec2-$AGENT_IP</agent_name>|" \
  /var/ossec/etc/ossec.conf

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent
%{ endif }

# ── CloudWatch Agent 설치 ────────────────────────────────
yum install -y amazon-cloudwatch-agent

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CW_EOF'
{
  "agent": {
    "metrics_collection_interval": 60,
    "region": "${aws_region}"
  },
  "metrics": {
    "namespace": "ECS/EC2",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60
      },
      "mem": {
        "measurement": ["mem_used_percent", "mem_available"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/"],
        "metrics_collection_interval": 60
      }
    }
  }
}
CW_EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

systemctl enable amazon-cloudwatch-agent