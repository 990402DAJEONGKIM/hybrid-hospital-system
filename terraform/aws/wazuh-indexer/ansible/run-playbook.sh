#!/bin/bash
# ──────────────────────────────────────────────────────────────
# 실행 순서: wazuh-indexer(이 파일) → wazuh-01 → wazuh-02
# 이 플레이북이 S3에 wazuh-install-files.tar를 업로드해야
# wazuh-01, wazuh-02 플레이북이 실행 가능합니다.
#
# 주의: vault.yml이 ansible-vault로 암호화되어 있는지 먼저 확인하세요.
#   확인 방법: head -1 ~/aws-network/wazuh-indexer/ansible/vault.yml
#   첫 줄이 $ANSIBLE_VAULT 로 시작해야 합니다.
#   암호화 방법: ansible-vault encrypt ~/aws-network/wazuh-indexer/ansible/vault.yml
# ──────────────────────────────────────────────────────────────
echo "S3에서 hosts.ini 다운로드..."
aws s3 cp s3://wazuh-ansible-ssm/wazuh-indexer/hosts.ini ~/aws-network/wazuh-indexer/ansible/hosts.ini

echo "Ansible playbook 실행..."
ansible-playbook -i ~/aws-network/wazuh-indexer/ansible/hosts.ini ~/aws-network/wazuh-indexer/ansible/wazuh-indexer.yaml --ask-vault-pass
