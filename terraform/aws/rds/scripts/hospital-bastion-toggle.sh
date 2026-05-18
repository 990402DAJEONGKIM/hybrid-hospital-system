#!/bin/bash
# ================================================================
# hospital-bastion-toggle.sh
# Bastion Host EC2 인스턴스 관리 스크립트
#
# 사용법:
#   ./hospital-bastion-toggle.sh stop    # 베스천 인스턴스 중지
#   ./hospital-bastion-toggle.sh start   # 베스천 인스턴스 시작
#   ./hospital-bastion-toggle.sh status  # 현재 상태 확인
# ================================================================

REGION="ap-south-2"
INSTANCE_NAME="aws-bastion-01"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

check_aws_cli() {
  if ! command -v aws &> /dev/null; then
    echo -e "${RED}[ERROR] AWS CLI가 설치되어 있지 않습니다.${NC}"
    exit 1
  fi
}

# ── 인스턴스 ID 자동 조회 ──────────────────────────────────────
get_instance_id() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null
}

get_instance_status() {
  local instance_id=$1
  aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null
}

get_instance_ip() {
  local instance_id=$1
  aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null
}

wait_for_instance() {
  local instance_id=$1
  local target=$2
  local elapsed=0
  echo -e "${CYAN}  인스턴스 대기 중 (목표: $target)...${NC}"
  while [ $elapsed -lt 300 ]; do
    local s=$(get_instance_status "$instance_id")
    echo -e "  [$(date +%H:%M:%S)] $s"
    [ "$s" = "$target" ] && echo -e "${GREEN}  완료${NC}" && return 0
    sleep 10; elapsed=$((elapsed+10))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

status_cmd() {
  echo -e "\n${CYAN}====== Bastion Host 현재 상태 ======${NC}"

  local instance_id=$(get_instance_id)

  if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
    echo -e "\n${RED}  인스턴스 없음 — Terraform으로 생성 필요${NC}"
    echo -e "  bastion_count = 1 로 설정 후 terraform apply\n"
    return
  fi

  local s=$(get_instance_status "$instance_id")
  local ip=$(get_instance_ip "$instance_id")

  echo -e "\n${YELLOW}[인스턴스]${NC} $INSTANCE_NAME ($instance_id)"
  if   [ "$s" = "running" ]; then echo -e "  ${GREEN}▶ 실행 중 — 비용 발생 중 (~\$0.0104/hr)${NC}"
  elif [ "$s" = "stopped" ]; then echo -e "  ${CYAN}■ 중지됨 — EBS 스토리지만 과금${NC}"
  else echo -e "  ${YELLOW}$s${NC}"; fi

  if [ -n "$ip" ] && [ "$ip" != "None" ]; then
    echo -e "  Public IP: ${GREEN}$ip${NC}"
  else
    echo -e "  Public IP: ${CYAN}없음 (중지 상태)${NC}"
  fi
  echo ""
}

stop_cmd() {
  echo -e "\n${YELLOW}====== Bastion Host 중지 ======${NC}"

  local instance_id=$(get_instance_id)

  if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
    echo -e "${RED}[ERROR] 인스턴스를 찾을 수 없습니다: $INSTANCE_NAME${NC}"
    exit 1
  fi

  local s=$(get_instance_status "$instance_id")

  if [ "$s" = "stopped" ]; then
    echo -e "${CYAN}  이미 중지 상태입니다.${NC}\n"
    exit 0
  fi

  if [ "$s" != "running" ]; then
    echo -e "${RED}  현재 상태 '$s' — 중지 불가${NC}"; exit 1
  fi

  echo -e "  인스턴스 ID: $instance_id"
  echo ""
  read -p "진행하시겠습니까? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "취소"; exit 0; }

  echo -e "\n${YELLOW}인스턴스 중지 중...${NC}"
  aws ec2 stop-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" --output text > /dev/null

  wait_for_instance "$instance_id" "stopped"

  echo -e "\n${GREEN}====== 중지 완료 ======${NC}"
  echo -e "  EBS 스토리지만 과금 (~\$0.10/GB/월)"
  echo -e "  SSM 접속 불가 상태\n"
}

start_cmd() {
  echo -e "\n${YELLOW}====== Bastion Host 시작 ======${NC}"

  local instance_id=$(get_instance_id)

  if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
    echo -e "${RED}[ERROR] 인스턴스를 찾을 수 없습니다: $INSTANCE_NAME${NC}"
    echo -e "${YELLOW}  Terraform으로 먼저 생성하세요:${NC}"
    echo -e "  bastion_count = 1 설정 후 terraform apply\n"
    exit 1
  fi

  local s=$(get_instance_status "$instance_id")

  if [ "$s" = "running" ]; then
    echo -e "${CYAN}  이미 실행 중입니다.${NC}"
    local ip=$(get_instance_ip "$instance_id")
    echo -e "  Public IP: ${GREEN}$ip${NC}\n"
    exit 0
  fi

  if [ "$s" != "stopped" ]; then
    echo -e "${RED}  현재 상태 '$s' — 시작 불가${NC}"; exit 1
  fi

  echo -e "  인스턴스 ID: $instance_id"
  echo -e "\n${YELLOW}인스턴스 시작 중...${NC}"
  aws ec2 start-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" --output text > /dev/null

  wait_for_instance "$instance_id" "running"

  # SSM Agent 준비 대기
  echo -e "${CYAN}  SSM Agent 준비 대기 중 (30초)...${NC}"
  sleep 30

  local ip=$(get_instance_ip "$instance_id")
  echo -e "\n${GREEN}====== 시작 완료 ======${NC}"
  echo -e "\n${CYAN}[접속 정보]${NC}"
  echo -e "  인스턴스 ID: ${GREEN}$instance_id${NC}"
  echo -e "  Public IP:   ${GREEN}$ip${NC}"
  echo -e "\n${CYAN}[SSM 접속 명령어]${NC}"
  echo -e "  aws ssm start-session \\"
  echo -e "    --target $instance_id \\"
  echo -e "    --document-name AWS-StartPortForwardingSessionToRemoteHost \\"
  echo -e "    --parameters '{\"host\":[\"<RDS_ENDPOINT>\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}'"
  echo ""
}

# ── 메인 ─────────────────────────────────────────────────────
check_aws_cli

case "$1" in
  stop)   stop_cmd ;;
  start)  start_cmd ;;
  status) status_cmd ;;
  *)
    echo ""
    echo -e "  사용법: $0 {stop|start|status}"
    echo ""
    echo -e "  ${GREEN}stop${NC}   — 베스천 인스턴스 중지 (비용 절감)"
    echo -e "  ${GREEN}start${NC}  — 베스천 인스턴스 시작 (SSM 접속 전)"
    echo -e "  ${GREEN}status${NC} — 현재 상태 확인"
    echo ""
    exit 1
    ;;
esac