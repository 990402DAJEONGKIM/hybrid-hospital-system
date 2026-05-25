#!/bin/bash
# ──────────────────────────────────────────────────────────────
# 실행 순서: wazuh-indexer(이 파일) → wazuh-01 → wazuh-02
# ──────────────────────────────────────────────────────────────

VAULT_PASS_FILE=$(mktemp)
read -s -p "Vault 비밀번호 입력: " VAULT_PASS
echo ""
echo "$VAULT_PASS" > "$VAULT_PASS_FILE"
chmod 600 "$VAULT_PASS_FILE"

echo "S3에서 hosts.ini 다운로드..."
aws s3 cp s3://wazuh-ansible-ssm/wazuh-indexer/hosts.ini ~/aws-network/wazuh-indexer/ansible/hosts.ini

echo "Ansible playbook 실행..."
ansible-playbook \
  -i ~/aws-network/wazuh-indexer/ansible/hosts.ini \
  ~/aws-network/wazuh-indexer/ansible/wazuh-indexer.yaml \
  --vault-password-file "$VAULT_PASS_FILE" \
  "$@"

rm -f "$VAULT_PASS_FILE"
echo "임시 vault 파일 삭제 완료"