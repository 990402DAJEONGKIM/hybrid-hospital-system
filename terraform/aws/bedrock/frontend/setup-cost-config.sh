#!/bin/bash
# 멀티클라우드 비용 분석 페이지 배포 스크립트 (초기 설치 및 유지보수용)
# SSM Parameter Store에서 API 정보를 읽어 admin_chat.html 안의 플레이스홀더를 실제 값으로 교체합니다.
# 실행 전 EC2에 SSM 읽기 권한(IAM Role)이 있어야 합니다.

set -euo pipefail

# 웹루트 결정: 인자로 받거나, nginx 설정에서 자동 감지 (서버마다 경로가 다름)
#   사용법: sudo ./setup-cost-config.sh [웹루트경로]
WEBROOT="${1:-}"
if [ -z "${WEBROOT}" ]; then
  WEBROOT=$(nginx -T 2>/dev/null | grep -oP '^\s*root\s+\K[^;]+' | head -1 | xargs)
fi
if [ -z "${WEBROOT}" ] || [ ! -d "${WEBROOT}" ]; then
  echo "오류: 웹루트를 찾을 수 없습니다. 경로를 인자로 지정하세요." >&2
  echo "  예) sudo $0 /usr/share/nginx/html" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML_FILE="${WEBROOT}/admin_chat.html"
echo "웹루트: ${WEBROOT}"

# ── SSM에서 값 읽기 ───────────────────────────────────
API_URL=$(aws ssm get-parameter \
  --name "/mzclinic/cost/chat/api-url" \
  --query "Parameter.Value" --output text)

API_KEY=$(aws ssm get-parameter \
  --name "/mzclinic/cost/chat/api-key" \
  --with-decryption \
  --query "Parameter.Value" --output text)

DASHBOARD_URL="${API_URL/chat/dashboard}"
REPORT_URL="${API_URL/chat/report}"

# ── HTML 파일 배포 (플레이스홀더 → 실제 값 치환) ────────
# 원본(git)에서 배포 경로로 복사한 뒤 sed로 값을 주입합니다.
# 키 값이 포함된 파일은 웹루트에만 존재하고 git에는 포함되지 않습니다.
cp "${SRC_DIR}/admin_chat.html" "${HTML_FILE}"

sed -i "s|%%COST_API_URL%%|${API_URL}|g"       "${HTML_FILE}"
sed -i "s|%%COST_API_KEY%%|${API_KEY}|g"       "${HTML_FILE}"
sed -i "s|%%COST_DASHBOARD_URL%%|${DASHBOARD_URL}|g" "${HTML_FILE}"
sed -i "s|%%COST_REPORT_URL%%|${REPORT_URL}|g" "${HTML_FILE}"

echo "배포 완료: ${HTML_FILE}"
echo "  API URL:       ${API_URL}"
echo "  Dashboard URL: ${DASHBOARD_URL}"
echo "  Report URL:    ${REPORT_URL}"
