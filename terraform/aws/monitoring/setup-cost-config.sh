#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════
# 멀티클라우드 비용 분석 페이지 배포 스크립트
# 2026-06-11 Sean: monitoring.mzclinic.cloud 3분할 패널 연동용 보강판
# ══════════════════════════════════════════════════════════════════════════
set -euo pipefail

# 사용법:
#   sudo bash setup-cost-config.sh /var/www/monitoring
# 인자를 생략하면 /var/www/monitoring을 우선 사용하고, 없으면 nginx 설정에서 root를 찾습니다.

WEBROOT="${1:-}"
WEBROOT_AUTO_DETECTED=false

if [ -z "${WEBROOT}" ]; then
  if [ -d "/var/www/monitoring" ]; then
    WEBROOT="/var/www/monitoring"
  else
    command -v nginx >/dev/null 2>&1 || {
      echo "오류: nginx 명령을 찾을 수 없습니다. 웹루트를 인자로 지정하세요." >&2
      echo "  예) sudo $0 /var/www/monitoring" >&2
      exit 1
    }
    WEBROOT="$(nginx -T 2>/dev/null | grep -oP '^\s*root\s+\K[^;]+' | head -1 | xargs || true)"
    WEBROOT_AUTO_DETECTED=true
  fi
fi

if [ -z "${WEBROOT}" ] || [ ! -d "${WEBROOT}" ]; then
  echo "오류: 웹루트를 찾을 수 없습니다. 경로를 인자로 지정하세요." >&2
  echo "  예) sudo $0 /var/www/monitoring" >&2
  exit 1
fi

command -v aws >/dev/null 2>&1 || { echo "오류: aws CLI가 필요합니다." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "오류: python3가 필요합니다." >&2; exit 1; }

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_HTML="${SRC_DIR}/admin_chat.html"
HTML_FILE="${WEBROOT}/admin_chat.html"
TMP_FILE="$(mktemp)"
trap 'rm -f "${TMP_FILE}"' EXIT

if [ ! -f "${SRC_HTML}" ]; then
  echo "오류: ${SRC_HTML} 파일을 찾을 수 없습니다." >&2
  exit 1
fi

echo "웹루트: ${WEBROOT} (자동감지: ${WEBROOT_AUTO_DETECTED})"

API_URL="$(aws ssm get-parameter \
  --name "/mzclinic/cost/chat/api-url" \
  --query "Parameter.Value" --output text)"

API_KEY="$(aws ssm get-parameter \
  --name "/mzclinic/cost/chat/api-key" \
  --with-decryption \
  --query "Parameter.Value" --output text)"

DASHBOARD_URL="${API_URL/chat/dashboard}"
REPORT_URL="${API_URL/chat/report}"

if [ -z "${API_URL}" ] || [ "${API_URL}" = "None" ] || [ -z "${API_KEY}" ] || [ "${API_KEY}" = "None" ]; then
  echo "오류: SSM에서 API URL 또는 API KEY를 읽지 못했습니다." >&2
  exit 1
fi

export API_URL API_KEY DASHBOARD_URL REPORT_URL SRC_HTML TMP_FILE
python3 - <<'PY'
import os
from pathlib import Path

src = Path(os.environ["SRC_HTML"])
dst = Path(os.environ["TMP_FILE"])
text = src.read_text(encoding="utf-8")
replacements = {
    "%%COST_API_URL%%": os.environ["API_URL"],
    "%%COST_API_KEY%%": os.environ["API_KEY"],
    "%%COST_DASHBOARD_URL%%": os.environ["DASHBOARD_URL"],
    "%%COST_REPORT_URL%%": os.environ["REPORT_URL"],
}
for old, new in replacements.items():
    text = text.replace(old, new)
if "%%COST_" in text:
    raise SystemExit("플레이스홀더 치환이 끝나지 않았습니다.")
dst.write_text(text, encoding="utf-8")
PY

install -m 0644 "${TMP_FILE}" "${HTML_FILE}"

echo "배포 완료: ${HTML_FILE}"
echo "  API URL:       ${API_URL}"
echo "  Dashboard URL: ${DASHBOARD_URL}"
echo "  Report URL:    ${REPORT_URL}"
