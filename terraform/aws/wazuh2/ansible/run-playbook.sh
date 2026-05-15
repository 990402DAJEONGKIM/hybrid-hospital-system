#!/bin/bash
echo "S3에서 hosts.ini 다운로드..."
aws s3 cp s3://wazuh-ansible-ssm/wazuh2/hosts.ini ~/aws-network/wazuh2/ansible/hosts.ini

echo "Ansible playbook 실행..."
ansible-playbook -i ~/aws-network/wazuh2/ansible/hosts.ini ~/aws-network/wazuh2/ansible/wazuh.yaml --ask-vault-pass
