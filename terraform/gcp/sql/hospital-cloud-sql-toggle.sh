#!/bin/bash
# ================================================================
# hospital-cloud-sql-toggle.sh
# GCP Cloud SQL 인스턴스 관리 스크립트
#
# 사용법:
#   ./hospital-cloud-sql-toggle.sh stop    # Cloud SQL 중지
#   ./hospital-cloud-sql-toggle.sh start   # Cloud SQL 시작
#   ./hospital-cloud-sql-toggle.sh status  # 현재 상태 확인
# ================================================================

PROJECT_ID="gcp-project-496802"
INSTANCE_NAME="gcp-cloud-sql"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

check_gcloud() {
  if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}[ERROR] gcloud CLI가 설치되어 있지 않습니다.${NC}"
    exit 1
  fi
}

get_instance_status() {
  gcloud sql instances describe "$INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --format="value(state)" 2>/dev/null
}

get_instance_ip() {
  gcloud sql instances describe "$INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --format="value(ipAddresses[0].ipAddress)" 2>/dev/null
}

wait_for_instance() {
  local target=$1
  local elapsed=0
  echo -e "${CYAN}  인스턴스 대기 중 (목표: $target)...${NC}"
  while [ $elapsed -lt 300 ]; do
    local s=$(get_instance_status)
    echo -e "  [$(date +%H:%M:%S)] $s"
    [ "$s" = "$target" ] && echo -e "${GREEN}  완료${NC}" && return 0
    sleep 10; elapsed=$((elapsed+10))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

status_cmd() {
  echo -e "\n${CYAN}====== Cloud SQL 현재 상태 ======${NC}"

  local s=$(get_instance_status)
  local ip=$(get_instance_ip)

  echo -e "\n${YELLOW}[인스턴스]${NC} $INSTANCE_NAME"
  if   [ "$s" = "RUNNABLE" ]; then echo -e "  ${GREEN}▶ 실행 중 — 비용 발생 중 (~\$0.05/hr)${NC}"
  elif [ "$s" = "STOPPED" ]; then echo -e "  ${CYAN}■ 중지됨 — 스토리지만 과금${NC}"
  else echo -e "  ${YELLOW}$s${NC}"; fi

  if [ -n "$ip" ] && [ "$ip" != "None" ]; then
    echo -e "  Private IP: ${GREEN}$ip${NC}"
  else
    echo -e "  Private IP: ${CYAN}없음 (중지 상태)${NC}"
  fi
  echo ""
}

stop_cmd() {
  echo -e "\n${YELLOW}====== Cloud SQL 중지 ======${NC}"

  local s=$(get_instance_status)

  if [ "$s" = "STOPPED" ]; then
    echo -e "${CYAN}  이미 중지 상태입니다.${NC}\n"
    exit 0
  fi

  if [ "$s" != "RUNNABLE" ]; then
    echo -e "${RED}  현재 상태 '$s' — 중지 불가${NC}"; exit 1
  fi

  echo -e "  인스턴스: $INSTANCE_NAME"
  echo ""
  read -p "진행하시겠습니까? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "취소"; exit 0; }

  echo -e "\n${YELLOW}인스턴스 중지 중...${NC}"
  gcloud sql instances patch "$INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --activation-policy=NEVER \
    --quiet

  wait_for_instance "STOPPED"

  echo -e "\n${GREEN}====== 중지 완료 ======${NC}"
  echo -e "  스토리지만 과금 (~\$0.17/GB/월)"
  echo -e "  pglogical 복제 중단됨\n"
}

start_cmd() {
  echo -e "\n${YELLOW}====== Cloud SQL 시작 ======${NC}"

  local s=$(get_instance_status)

  if [ "$s" = "RUNNABLE" ]; then
    echo -e "${CYAN}  이미 실행 중입니다.${NC}"
    local ip=$(get_instance_ip)
    echo -e "  Private IP: ${GREEN}$ip${NC}\n"
    exit 0
  fi

  if [ "$s" != "STOPPED" ]; then
    echo -e "${RED}  현재 상태 '$s' — 시작 불가${NC}"; exit 1
  fi

  echo -e "${YELLOW}인스턴스 시작 중...${NC}"
  gcloud sql instances patch "$INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --activation-policy=ALWAYS \
    --quiet

  wait_for_instance "RUNNABLE"

  local ip=$(get_instance_ip)
  echo -e "\n${GREEN}====== 시작 완료 ======${NC}"
  echo -e "\n${CYAN}[접속 정보]${NC}"
  echo -e "  인스턴스:   ${GREEN}$INSTANCE_NAME${NC}"
  echo -e "  Private IP: ${GREEN}$ip${NC}"
  echo -e "\n${YELLOW}※ pglogical 복제가 중단됐던 경우 구독 상태를 확인하세요:${NC}"
  echo -e "  SELECT subscription_name, status FROM pglogical.show_subscription_status();\n"
}

# ── 메인 ─────────────────────────────────────────────────────
check_gcloud

case "$1" in
  stop)   stop_cmd ;;
  start)  start_cmd ;;
  status) status_cmd ;;
  *)
    echo ""
    echo -e "  사용법: $0 {stop|start|status}"
    echo ""
    echo -e "  ${GREEN}stop${NC}   — Cloud SQL 중지 (비용 절감)"
    echo -e "  ${GREEN}start${NC}  — Cloud SQL 시작"
    echo -e "  ${GREEN}status${NC} — 현재 상태 확인"
    echo ""
    exit 1
    ;;
esac
