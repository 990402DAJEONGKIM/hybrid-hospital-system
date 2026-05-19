#!/bin/bash
# ──────────────────────────────────────────────────────────────
# 주의: 이 플레이북은 wazuh-indexer 플레이북이 먼저 실행된 후에 실행해야 합니다.
# Indexer가 wazuh-install-files.tar를 S3에 업로드하지 않으면 이 플레이북이 실패합니다.
# 실행 순서: wazuh-indexer → wazuh-01(이 파일) → wazuh-02
#
# 주의: vault.yml이 ansible-vault로 암호화되어 있는지 먼저 확인하세요.
#   확인 방법: head -1 ~/aws-network/wazuh/ansible/vault.yml
#   첫 줄이 $ANSIBLE_VAULT 로 시작해야 합니다.
# ──────────────────────────────────────────────────────────────

echo "S3에서 hosts.ini 다운로드..."
aws s3 cp s3://wazuh-ansible-ssm/wazuh1/hosts.ini ~/aws-network/wazuh/ansible/hosts.ini

echo "Ansible playbook 실행..."
ansible-playbook -i ~/aws-network/wazuh/ansible/hosts.ini ~/aws-network/wazuh/ansible/wazuh.yaml --ask-vault-pass
