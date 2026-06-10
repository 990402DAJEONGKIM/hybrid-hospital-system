#!/bin/bash
# ──────────────────────────────────────────────────────────────
# 실행 순서: wazuh-indexer(이 파일) → wazuh-01 → wazuh-02
# ──────────────────────────────────────────────────────────────

if [ ! -f ~/aws-network/wazuh-indexer/ansible/hosts.ini ]; then
  echo "hosts.ini 없음. 먼저 ./host.sh 실행하세요."
  exit 1
fi

echo "Ansible playbook 실행..."
ansible-playbook \
  -i ~/aws-network/wazuh-indexer/ansible/hosts.ini \
  ~/aws-network/wazuh-indexer/ansible/wazuh-indexer.yaml \
  --vault-id @prompt