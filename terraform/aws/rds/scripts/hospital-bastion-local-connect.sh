#!/bin/bash
# ================================================================
# hospital-bastion-local-connect.sh
# 로컬 PC → 베스천 호스트 SSM 포트 포워딩 연결 스크립트
#
# 사용법:
#   ./hospital-bastion-local-connect.sh        # SSM 터널 연결
#   ./hospital-bastion-local-connect.sh status # 현재 상태 확인
# ================================================================

REGION="ap-south-2"
INSTANCE_NAME="aws-bastion-01"
CLUSTER_ID="aws-aurora-01"
LOCAL_PORT="15432"
RDS_PORT="5432"

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

check_session_manager_plugin() {
  if ! command -v session-manager-plugin &> /dev/null; then
    echo -e "${RED}[ERROR] Session Manager Plugin이 설치되어 있지 않습니다.${NC}"
    echo -e "${YELLOW}  설치 방법:${NC}"
    echo -e "  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
    exit 1
  fi
}

get_instance_id() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=running" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null
}

get_instance_status() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null
}

get_rds_endpoint() {
  aws rds describe-db-clusters \
    --db-cluster-identifier "$CLUSTER_ID" \
    --region "$REGION" \
    --query 'DBClusters[0].Endpoint' \
    --output text 2>/dev/null
}

status_cmd() {
  echo -e "\n${CYAN}====== SSM 연결 상태 확인 ======${NC}\n"

  # 베스천 상태
  local instance_status=$(get_instance_status)
  echo -e "${YELLOW}[베스천 호스트]${NC} $INSTANCE_NAME"
  if [ "$instance_status" = "running" ]; then
    echo -e "  ${GREEN}▶ 실행 중${NC}"
  elif [ "$instance_status" = "stopped" ]; then
    echo -e "  ${RED}■ 중지됨 — hospital-bastion-toggle.sh start 실행 필요${NC}"
  else
    echo -e "  ${RED}확인 불가 (인스턴스 없음)${NC}"
  fi

  # RDS 엔드포인트
  local rds_endpoint=$(get_rds_endpoint)
  echo -e "\n${YELLOW}[Aurora 클러스터]${NC} $CLUSTER_ID"
  if [ -n "$rds_endpoint" ] && [ "$rds_endpoint" != "None" ]; then
    echo -e "  ${GREEN}엔드포인트: $rds_endpoint${NC}"
  else
    echo -e "  ${RED}엔드포인트 조회 실패${NC}"
  fi

  # 로컬 포트 사용 여부
  echo -e "\n${YELLOW}[로컬 포트]${NC} $LOCAL_PORT"
  if lsof -i :$LOCAL_PORT &>/dev/null; then
    echo -e "  ${GREEN}▶ 사용 중 — 터널 연결됨${NC}"
  else
    echo -e "  ${CYAN}■ 미사용 — 터널 연결 안됨${NC}"
  fi
  echo ""
}

connect_cmd() {
  echo -e "\n${CYAN}====== SSM 포트 포워딩 연결 ======${NC}\n"

  # 1. 베스천 인스턴스 ID 조회
  echo -e "${CYAN}[1/3] 베스천 인스턴스 조회 중...${NC}"
  local instance_id=$(get_instance_id)

  if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
    echo -e "${RED}[ERROR] 실행 중인 베스천 인스턴스가 없습니다.${NC}"
    echo -e "${YELLOW}  먼저 실행하세요: ./hospital-bastion-toggle.sh start${NC}\n"
    exit 1
  fi
  echo -e "  인스턴스 ID: ${GREEN}$instance_id${NC}"

  # 2. RDS 엔드포인트 조회
  echo -e "\n${CYAN}[2/3] RDS 엔드포인트 조회 중...${NC}"
  local rds_endpoint=$(get_rds_endpoint)

  if [ -z "$rds_endpoint" ] || [ "$rds_endpoint" = "None" ]; then
    echo -e "${RED}[ERROR] RDS 엔드포인트를 찾을 수 없습니다.${NC}\n"
    exit 1
  fi
  echo -e "  RDS 엔드포인트: ${GREEN}$rds_endpoint${NC}"

  # 3. 로컬 포트 사용 여부 확인
  echo -e "\n${CYAN}[3/3] 로컬 포트 확인 중...${NC}"
  if lsof -i :$LOCAL_PORT &>/dev/null; then
    echo -e "${RED}[ERROR] 로컬 포트 $LOCAL_PORT 가 이미 사용 중입니다.${NC}"
    echo -e "${YELLOW}  기존 터널을 먼저 종료하세요.${NC}\n"
    exit 1
  fi
  echo -e "  로컬 포트 $LOCAL_PORT: ${GREEN}사용 가능${NC}"

  # 4. SSM 터널 연결
  echo -e "\n${GREEN}====== SSM 터널 연결 시작 ======${NC}"
  echo -e "  베스천:     ${GREEN}$instance_id${NC}"
  echo -e "  RDS:        ${GREEN}$rds_endpoint:$RDS_PORT${NC}"
  echo -e "  로컬 포트:  ${GREEN}$LOCAL_PORT${NC}"
  echo -e "\n${CYAN}터널이 열리면 아래 정보로 DB 접속하세요:${NC}"
  echo -e "  Host:     ${GREEN}127.0.0.1${NC}"
  echo -e "  Port:     ${GREEN}$LOCAL_PORT${NC}"
  echo -e "\n${YELLOW}종료하려면 Ctrl+C 를 누르세요.${NC}\n"

  # Ctrl+C 시 SSM 프로세스도 같이 종료
  trap 'echo -e "\n${RED}터널 종료 중...${NC}"; kill $SSM_PID 2>/dev/null; exit 0' INT TERM

  aws ssm start-session \
    --target "$instance_id" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$rds_endpoint\"],\"portNumber\":[\"$RDS_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
    --region "$REGION" &

  SSM_PID=$!
  echo -e "${CYAN}SSM PID: $SSM_PID${NC}"

  # 30초마다 keepalive (idle 타임아웃 방지)
  while kill -0 $SSM_PID 2>/dev/null; do
    sleep 30
    echo -e "${CYAN}[keepalive] $(date '+%Y-%m-%d %H:%M:%S') — 연결 유지 중...${NC}"
  done

  echo -e "${RED}SSM 세션이 종료되었습니다.${NC}"
}

# ── 메인 ─────────────────────────────────────────────────────
check_aws_cli
check_session_manager_plugin

case "$1" in
  status) status_cmd ;;
  "")     connect_cmd ;;
  *)
    echo ""
    echo -e "  사용법: $0 {status}"
    echo ""
    echo -e "  ${GREEN}(없음)${NC}  — SSM 터널 연결"
    echo -e "  ${GREEN}status${NC} — 현재 연결 상태 확인"
    echo ""
    exit 1
    ;;
esac