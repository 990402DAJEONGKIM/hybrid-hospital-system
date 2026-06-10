#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════
# 멀티클라우드 비용 분석 페이지 배포 스크립트
# ══════════════════════════════════════════════════════════════════════════
#
# ▣ 이 스크립트가 하는 일 (3단계)
#   1. nginx 설정에서 웹루트(HTML 서빙 폴더)를 자동으로 찾는다
#   2. AWS SSM Parameter Store에서 API 주소와 API 키를 읽어온다
#   3. admin_chat.html을 웹루트로 복사하면서, 파일 안의 플레이스홀더
#      (%%COST_API_URL%% 등)를 실제 값으로 바꿔치기한다
#
# ▣ 왜 이런 방식을 쓰나?
#   API 키를 git에 올리면 안 되기 때문에, 원본 HTML에는 가짜 표시
#   (%%...%%)만 넣어두고, 배포하는 순간에 실제 값을 주입한다.
#   → 키가 들어간 완성본은 서버의 웹루트에만 존재하고 git에는 없다.
#
# ▣ 사용법
#   sudo bash setup-cost-config.sh              # 웹루트 자동 감지
#   sudo bash setup-cost-config.sh /var/www/monitoring   # 웹루트 직접 지정
#
# ▣ 실행 전 조건
#   - 이 스크립트와 admin_chat.html이 같은 폴더에 있어야 함
#   - 서버의 IAM 역할에 SSM 파라미터 읽기 권한이 있어야 함
#     (AmazonSSMManagedInstanceCore 정책이면 충분)
# ══════════════════════════════════════════════════════════════════════════

# 안전장치 3종 세트:
#   -e: 명령 하나라도 실패하면 즉시 중단 (반쯤 배포된 상태 방지)
#   -u: 선언 안 된 변수를 쓰면 오류 (오타로 빈 값이 들어가는 사고 방지)
#   -o pipefail: 파이프(|) 중간 명령이 실패해도 실패로 처리
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# [1단계] 웹루트 결정
#   서버마다 nginx가 HTML을 서빙하는 폴더가 다르다.
#   (예: 테스트 서버 /usr/share/nginx/html, 모니터링 서버 /var/www/monitoring)
#   그래서 고정 경로 대신, 실행 시점에 알아내는 방식을 쓴다.
# ──────────────────────────────────────────────────────────────────────────

# $1 = 스크립트 실행 시 붙인 첫 번째 인자. 없으면 빈 문자열("")로 시작.
WEBROOT="${1:-}"

# 인자를 안 줬으면 nginx 설정에서 자동으로 찾는다.
#   nginx -T          : 현재 적용 중인 nginx 설정 전체를 출력
#   grep -oP '...'    : 그 출력에서 "root /경로;" 줄을 찾아 경로 부분만 추출
#   head -1           : 여러 개 나오면 첫 번째 것만 사용
#   xargs             : 앞뒤 공백 제거
WEBROOT_AUTO_DETECTED=false
if [ -z "${WEBROOT}" ]; then
  WEBROOT=$(nginx -T 2>/dev/null | grep -oP '^\s*root\s+\K[^;]+' | head -1 | xargs)
  WEBROOT_AUTO_DETECTED=true
fi

# 그래도 못 찾았거나, 찾은 경로가 실제 폴더가 아니면 → 사용법 안내 후 종료
if [ -z "${WEBROOT}" ] || [ ! -d "${WEBROOT}" ]; then
  echo "오류: 웹루트를 찾을 수 없습니다. 경로를 인자로 지정하세요." >&2
  echo "  예) sudo $0 /usr/share/nginx/html" >&2
  exit 1
fi

# SRC_DIR = 이 스크립트 파일이 놓여 있는 폴더의 절대경로.
#   dirname "$0" : 스크립트 경로에서 폴더 부분만 추출
#   cd ... && pwd: 상대경로여도 절대경로로 변환
# → 어느 위치에서 실행해도 "스크립트 옆에 있는" admin_chat.html을 정확히 찾는다.
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# 배포 결과물(완성본 HTML)이 놓일 최종 경로
HTML_FILE="${WEBROOT}/admin_chat.html"

echo "웹루트: ${WEBROOT} (자동감지: ${WEBROOT_AUTO_DETECTED})"

# ──────────────────────────────────────────────────────────────────────────
# [2단계] SSM Parameter Store에서 비밀 값 읽기
#   AWS의 "비밀 금고"에서 API 주소와 키를 꺼낸다.
#   값은 AWS 콘솔 → Systems Manager → Parameter Store에서 관리한다.
# ──────────────────────────────────────────────────────────────────────────

# API Gateway의 챗봇 엔드포인트 주소 (일반 문자열이라 복호화 불필요)
API_URL=$(aws ssm get-parameter \
  --name "/mzclinic/cost/chat/api-url" \
  --query "Parameter.Value" --output text)

# API 키 (SecureString으로 암호화 저장되어 있어 --with-decryption 필요)
API_KEY=$(aws ssm get-parameter \
  --name "/mzclinic/cost/chat/api-key" \
  --with-decryption \
  --query "Parameter.Value" --output text)

# 대시보드/보고서 주소는 따로 저장하지 않고, 챗봇 주소에서 파생시킨다.
#   ${변수/찾을문자열/바꿀문자열} = bash의 문자열 치환 문법
#   예) .../prod/chat → .../prod/dashboard, .../prod/report
DASHBOARD_URL="${API_URL/chat/dashboard}"
REPORT_URL="${API_URL/chat/report}"

# ──────────────────────────────────────────────────────────────────────────
# [3단계] HTML 복사 + 플레이스홀더 치환
#   원본을 웹루트로 복사한 뒤, sed로 가짜 표시를 실제 값으로 교체한다.
# ──────────────────────────────────────────────────────────────────────────

# 원본(git 관리 파일, 플레이스홀더 상태)을 웹루트로 복사
cp "${SRC_DIR}/admin_chat.html" "${HTML_FILE}"

# sed -i "s|찾을것|바꿀것|g" 파일  → 파일 안의 문자열을 직접 교체
#   구분자로 / 대신 | 를 쓰는 이유: URL에 / 가 들어 있어서 충돌하기 때문
#   g 플래그: 한 줄에 여러 번 나와도 전부 교체
sed -i "s|%%COST_API_URL%%|${API_URL}|g"             "${HTML_FILE}"
sed -i "s|%%COST_API_KEY%%|${API_KEY}|g"             "${HTML_FILE}"
sed -i "s|%%COST_DASHBOARD_URL%%|${DASHBOARD_URL}|g" "${HTML_FILE}"
sed -i "s|%%COST_REPORT_URL%%|${REPORT_URL}|g"       "${HTML_FILE}"

# ──────────────────────────────────────────────────────────────────────────
# 완료 보고 (API 키는 보안상 화면에 출력하지 않는다)
# ──────────────────────────────────────────────────────────────────────────
echo "배포 완료: ${HTML_FILE}"
echo "  API URL:       ${API_URL}"
echo "  Dashboard URL: ${DASHBOARD_URL}"
echo "  Report URL:    ${REPORT_URL}"
