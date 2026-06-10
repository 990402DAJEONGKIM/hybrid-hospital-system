#!/bin/bash
# 멀티클라우드 비용 분석 페이지 설정 스크립트 (초기 설치 및 유지보수용)
# SSM Parameter Store에서 API 정보를 읽어 cost-config.js를 생성합니다.
# 실행 전 EC2에 SSM 읽기 권한(IAM Role)이 있어야 합니다.

# API Gateway 엔드포인트 (SSM String)
API_URL=$(aws ssm get-parameter \
  --name "/mzclinic/cost/chat/api-url" \
  --query "Parameter.Value" --output text)

# API Key (SSM SecureString - 복호화 필요)
API_KEY=$(aws ssm get-parameter \
  --name "/mzclinic/cost/chat/api-key" \
  --with-decryption \
  --query "Parameter.Value" --output text)

# cost-config.js 생성 (nginx 웹루트에 저장)
# 이 파일은 git에 포함되지 않으며 서버에만 존재합니다.
# COST_API_URL에서 /chat → /dashboard, /report 경로를 자동 계산합니다.
cat > /var/www/html/cost-config.js <<EOF
window.COST_API_URL       = "${API_URL}";
window.COST_API_KEY       = "${API_KEY}";
window.COST_DASHBOARD_URL = "${API_URL/chat/dashboard}";
window.COST_REPORT_URL    = "${API_URL/chat/report}";
EOF

echo "cost-config.js 생성 완료"
