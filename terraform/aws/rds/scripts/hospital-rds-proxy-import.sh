#!/bin/bash
# ================================================================
# hospital-rds-proxy-import.sh
# RDS Proxy start 후 Terraform state 동기화 스크립트
# (by 김다정, 2026.06.01)
#
# 사용법:
#   ./hospital-rds-proxy-import.sh
#
# 실행 전 필수 조건:
#   1. hospital-rds-toggle.sh start 완료
#   2. terraform login (TFC 토큰 인증) 완료
#   3. 이 스크립트는 terraform/aws/rds/ 디렉터리 기준으로 실행
# ================================================================

PROXY_NAME="aws-rds-proxy-01"
READER_ENDPOINT_NAME="aws-rds-proxy-01-reader"
REGION="ap-south-2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 스크립트 위치에서 terraform 디렉터리로 이동 ───────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── 사전 체크 ─────────────────────────────────────────────────
check_requirements() {
  echo -e "${CYAN}[사전 체크]${NC}"

  if ! command -v terraform &> /dev/null; then
    echo -e "${RED}  [ERROR] terraform CLI가 설치되어 있지 않습니다.${NC}"
    exit 1
  fi

  if ! command -v aws &> /dev/null; then
    echo -e "${RED}  [ERROR] AWS CLI가 설치되어 있지 않습니다.${NC}"
    exit 1
  fi

  # Proxy 존재 여부 확인
  local proxy_status
  proxy_status=$(aws rds describe-db-proxies \
    --db-proxy-name "$PROXY_NAME" \
    --region "$REGION" \
    --query 'DBProxies[0].Status' \
    --output text 2>/dev/null)

  if [ -z "$proxy_status" ] || [ "$proxy_status" = "None" ] || [ "$proxy_status" = "null" ]; then
    echo -e "${RED}  [ERROR] Proxy '$PROXY_NAME' 가 AWS에 존재하지 않습니다.${NC}"
    echo -e "${YELLOW}  hospital-rds-toggle.sh start 를 먼저 실행하세요.${NC}"
    exit 1
  fi

  echo -e "  Proxy 상태: ${GREEN}$proxy_status${NC}"

  # Reader Endpoint 존재 여부 확인
  local reader_status
  reader_status=$(aws rds describe-db-proxy-endpoints \
    --db-proxy-name "$PROXY_NAME" \
    --db-proxy-endpoint-name "$READER_ENDPOINT_NAME" \
    --region "$REGION" \
    --query 'DBProxyEndpoints[0].Status' \
    --output text 2>/dev/null)

  if [ -z "$reader_status" ] || [ "$reader_status" = "None" ] || [ "$reader_status" = "null" ]; then
    echo -e "${RED}  [ERROR] Reader Endpoint '$READER_ENDPOINT_NAME' 가 AWS에 존재하지 않습니다.${NC}"
    exit 1
  fi

  echo -e "  Reader Endpoint 상태: ${GREEN}$reader_status${NC}"
  echo ""
}

# ── terraform import 실행 ─────────────────────────────────────
run_import() {
  echo -e "${YELLOW}[Terraform state 동기화 시작]${NC}"
  echo -e "  디렉터리: $TF_DIR"
  echo ""

  cd "$TF_DIR" || { echo -e "${RED}[ERROR] 디렉터리 이동 실패: $TF_DIR${NC}"; exit 1; }

  # (추가 by 김다정, 2026.06.01) stop → start 후 구 Proxy가 state에 남아 있으면 import 실패
  # import 전에 state rm 으로 먼저 제거 (이미 없으면 무시)
  echo -e "${CYAN}[사전 정리] 기존 state 항목 제거 (있을 경우만)...${NC}"
  terraform state rm aws_db_proxy.main                    2>/dev/null && echo -e "  aws_db_proxy.main 제거됨" || true
  terraform state rm aws_db_proxy_default_target_group.main 2>/dev/null && echo -e "  aws_db_proxy_default_target_group.main 제거됨" || true
  terraform state rm 'aws_db_proxy_endpoint.reader'       2>/dev/null && echo -e "  aws_db_proxy_endpoint.reader 제거됨" || true
  echo ""

  # 1. aws_db_proxy.main
  echo -e "${CYAN}[1/3] aws_db_proxy.main import...${NC}"
  if terraform import aws_db_proxy.main "$PROXY_NAME"; then
    echo -e "${GREEN}  완료${NC}"
  else
    echo -e "${RED}  [ERROR] import 실패 — TFC 인증을 확인하세요.${NC}"
    exit 1
  fi
  echo ""

  # 2. aws_db_proxy_default_target_group.main
  echo -e "${CYAN}[2/3] aws_db_proxy_default_target_group.main import...${NC}"
  if terraform import aws_db_proxy_default_target_group.main "$PROXY_NAME"; then
    echo -e "${GREEN}  완료${NC}"
  else
    echo -e "${RED}  [ERROR] import 실패${NC}"
    exit 1
  fi
  echo ""

  # 3. aws_db_proxy_endpoint.reader
  echo -e "${CYAN}[3/3] aws_db_proxy_endpoint.reader import...${NC}"
  if terraform import 'aws_db_proxy_endpoint.reader' "${PROXY_NAME}/${READER_ENDPOINT_NAME}"; then
    echo -e "${GREEN}  완료${NC}"
  else
    echo -e "${RED}  [ERROR] import 실패${NC}"
    exit 1
  fi
  echo ""

  echo -e "${GREEN}====== Terraform state 동기화 완료 ======${NC}"
  echo -e "  terraform plan 으로 drift 없음을 확인하세요."
  echo ""
}

# ── 메인 ─────────────────────────────────────────────────────
check_requirements
run_import
