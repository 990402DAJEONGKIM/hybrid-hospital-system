#!/bin/bash
# ──────────────────────────────────────────────────────────────
# 실행 순서: wazuh-indexer → wazuh-01 → wazuh-02(이 파일)
# 사전 조건: ./host.sh 먼저 실행해서 hosts.ini 생성 필요
# ──────────────────────────────────────────────────────────────

if [ ! -f ~/aws-network/wazuh2/ansible/hosts.ini ]; then
  echo "hosts.ini 없음. 먼저 ./host.sh 실행하세요."
  exit 1
fi

echo "Ansible playbook 실행..."
ansible-playbook \
  -i ~/aws-network/wazuh2/ansible/hosts.ini \
  ~/aws-network/wazuh2/ansible/wazuh.yaml \
  --vault-id @prompt