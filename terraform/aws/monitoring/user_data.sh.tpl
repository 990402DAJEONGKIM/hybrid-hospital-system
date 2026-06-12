#!/bin/bash
# monitoring EC2 초기화 - S3 스크립트 실행
# 수정 260612 김강환: 전체 로직 S3로 분리, 변수 AWS CLI 런타임 조회
set -e

aws s3 cp "s3://aws-k2p-storage-01/grafana/scripts/user_data.sh" \
  "/tmp/user_data.sh" --region ap-south-2

chmod +x /tmp/user_data.sh
bash /tmp/user_data.sh >> /var/log/monitoring-setup.log 2>&1
