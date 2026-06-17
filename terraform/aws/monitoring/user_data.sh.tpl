#!/bin/bash
# monitoring EC2 초기화 - S3 스크립트 실행
# 수정 260612 김강환: 전체 로직 S3로 분리, 변수 AWS CLI 런타임 조회
set -e

apt-get update -y
apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

aws s3 cp "s3://aws-k2p-storage-01/monitoring/grafana/scripts/user_data.sh" \
  "/tmp/user_data_main.sh" --region ap-south-2

chmod +x /tmp/user_data_main.sh
bash /tmp/user_data_main.sh >> /var/log/monitoring-setup.log 2>&1