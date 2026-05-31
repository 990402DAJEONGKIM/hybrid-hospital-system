#!/bin/bash
# ================================================================
# hospital-rds-toggle.sh
# Aurora 클러스터 + RDS Proxy 통합 관리 스크립트
#
# 사용법:
#   ./hospital-rds-toggle.sh stop    # Proxy 삭제 + 클러스터 중지
#   ./hospital-rds-toggle.sh start   # 클러스터 시작 + Proxy 재생성
#   ./hospital-rds-toggle.sh status  # 현재 상태 확인
# ================================================================

REGION="ap-south-2"
CLUSTER_ID="aws-aurora-01"
PROXY_NAME="aws-rds-proxy-01"
PROXY_ROLE_NAME="aws-rds-proxy-role"
SUBNET_GROUP_NAME="aws-db-subnet-group-01"
PROXY_SG_NAME="aws-proxy-sg"
SECRET_NAME_HOSPITAL="aws-secret-rds-hospital-user"
SECRET_NAME_API="aws-secret-rds-api-user"
# (by 김다정, 2026.06.01) Reader Endpoint 이름 추가 — start 시 재생성, stop 시 Proxy 삭제와 함께 자동 삭제됨
READER_ENDPOINT_NAME="aws-rds-proxy-01-reader"

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

# ── 동적 값 자동 조회 ─────────────────────────────────────────
resolve_config() {
  echo -e "${CYAN}[설정 자동 조회 중...]${NC}"

  ACCOUNT_ID=$(aws sts get-caller-identity \
    --query 'Account' --output text 2>/dev/null)
  if [ -z "$ACCOUNT_ID" ]; then
    echo -e "${RED}[ERROR] AWS 자격증명이 설정되어 있지 않습니다. aws configure 를 먼저 실행하세요.${NC}"
    exit 1
  fi

  PROXY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PROXY_ROLE_NAME}"

  SECRET_ARN_HOSPITAL=$(aws secretsmanager describe-secret \
    --secret-id "$SECRET_NAME_HOSPITAL" \
    --region "$REGION" \
    --query 'ARN' --output text 2>/dev/null)

  SECRET_ARN_API=$(aws secretsmanager describe-secret \
    --secret-id "$SECRET_NAME_API" \
    --region "$REGION" \
    --query 'ARN' --output text 2>/dev/null)

  PROXY_SUBNET_IDS=$(aws rds describe-db-subnet-groups \
    --db-subnet-group-name "$SUBNET_GROUP_NAME" \
    --region "$REGION" \
    --query 'DBSubnetGroups[0].Subnets[*].SubnetIdentifier' \
    --output text 2>/dev/null)

  PROXY_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PROXY_SG_NAME}" "Name=vpc-id,Values=$(get_vpc_id)" \
    --region "$REGION" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null)

  # 검증
  local errors=0
  [ -z "$SECRET_ARN_HOSPITAL" ] && echo -e "${RED}  [ERROR] 시크릿 없음: $SECRET_NAME_HOSPITAL${NC}" && errors=$((errors+1))
  [ -z "$SECRET_ARN_API" ]      && echo -e "${RED}  [ERROR] 시크릿 없음: $SECRET_NAME_API${NC}"      && errors=$((errors+1))
  [ -z "$PROXY_SUBNET_IDS" ]    && echo -e "${RED}  [ERROR] 서브넷 그룹 없음: $SUBNET_GROUP_NAME${NC}" && errors=$((errors+1))
  [ -z "$PROXY_SG_ID" ] || [ "$PROXY_SG_ID" = "None" ] && echo -e "${RED}  [ERROR] 보안 그룹 없음: $PROXY_SG_NAME${NC}" && errors=$((errors+1))

  if [ $errors -gt 0 ]; then
    echo -e "${RED}[ERROR] 설정 조회 실패. 리소스 이름 또는 AWS 권한을 확인하세요.${NC}"
    exit 1
  fi

  echo -e "  계정 ID:   ${GREEN}$ACCOUNT_ID${NC}"
  echo -e "  시크릿:    ${GREEN}조회 완료${NC}"
  echo -e "  서브넷:    ${GREEN}$PROXY_SUBNET_IDS${NC}"
  echo -e "  SG:        ${GREEN}$PROXY_SG_ID${NC}"
  echo ""
}

get_vpc_id() {
  aws rds describe-db-clusters \
    --db-cluster-identifier "$CLUSTER_ID" \
    --region "$REGION" \
    --query 'DBClusters[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
    --output text 2>/dev/null | xargs -I{} aws ec2 describe-security-groups \
    --group-ids {} \
    --region "$REGION" \
    --query 'SecurityGroups[0].VpcId' \
    --output text 2>/dev/null
}

get_cluster_status() {
  aws rds describe-db-clusters \
    --db-cluster-identifier "$CLUSTER_ID" \
    --region "$REGION" \
    --query 'DBClusters[0].Status' \
    --output text 2>/dev/null
}

get_instances_status() {
  aws rds describe-db-instances \
    --region "$REGION" \
    --query "DBInstances[?DBClusterIdentifier=='$CLUSTER_ID'].[DBInstanceIdentifier,DBInstanceStatus]" \
    --output table 2>/dev/null
}

get_proxy_status() {
  aws rds describe-db-proxies \
    --db-proxy-name "$PROXY_NAME" \
    --region "$REGION" \
    --query 'DBProxies[0].Status' \
    --output text 2>/dev/null
}

proxy_exists() {
  local s=$(get_proxy_status)
  [[ -n "$s" && "$s" != "None" && "$s" != "null" ]]
}

wait_for_cluster() {
  local target=$1
  local elapsed=0
  echo -e "${CYAN}  클러스터 대기 중 (목표: $target)...${NC}"
  while [ $elapsed -lt 600 ]; do
    local s=$(get_cluster_status)
    echo -e "  [$(date +%H:%M:%S)] $s"
    [ "$s" = "$target" ] && echo -e "${GREEN}  완료${NC}" && return 0
    sleep 15; elapsed=$((elapsed+15))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

wait_for_proxy() {
  local target=$1
  local elapsed=0
  echo -e "${CYAN}  Proxy 대기 중 (목표: $target)...${NC}"
  while [ $elapsed -lt 600 ]; do
    local s=$(get_proxy_status)
    echo -e "  [$(date +%H:%M:%S)] $s"
    [ "$s" = "$target" ] && echo -e "${GREEN}  완료${NC}" && return 0
    sleep 15; elapsed=$((elapsed+15))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

# (by 김다정, 2026.06.01) Reader Endpoint 상태 조회
get_reader_endpoint_status() {
  aws rds describe-db-proxy-endpoints \
    --db-proxy-name "$PROXY_NAME" \
    --db-proxy-endpoint-name "$READER_ENDPOINT_NAME" \
    --region "$REGION" \
    --query 'DBProxyEndpoints[0].Status' \
    --output text 2>/dev/null
}

# (by 김다정, 2026.06.01) Reader Endpoint available 대기
wait_for_reader_endpoint() {
  local elapsed=0
  echo -e "${CYAN}  Reader Endpoint 대기 중 (목표: available)...${NC}"
  while [ $elapsed -lt 600 ]; do
    local s=$(get_reader_endpoint_status)
    echo -e "  [$(date +%H:%M:%S)] $s"
    [ "$s" = "available" ] && echo -e "${GREEN}  완료${NC}" && return 0
    sleep 15; elapsed=$((elapsed+15))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

wait_proxy_deleted() {
  local elapsed=0
  echo -e "${CYAN}  Proxy 삭제 대기 중...${NC}"
  while [ $elapsed -lt 1800 ]; do
    proxy_exists || { echo -e "${GREEN}  삭제 완료${NC}"; return 0; }
    echo -e "  [$(date +%H:%M:%S)] 삭제 중..."
    sleep 15; elapsed=$((elapsed+15))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

status_cmd() {
  echo -e "\n${CYAN}====== RDS 리소스 현재 상태 ======${NC}"

  local cs=$(get_cluster_status)
  echo -e "\n${YELLOW}[클러스터]${NC} $CLUSTER_ID"
  if   [ "$cs" = "available" ]; then echo -e "  ${GREEN}▶ 실행 중 — 비용 발생 중${NC}"
  elif [ "$cs" = "stopped"   ]; then echo -e "  ${CYAN}■ 중지됨 — 스토리지만 과금${NC}"
  else echo -e "  ${YELLOW}$cs${NC}"; fi

  echo -e "\n${YELLOW}[인스턴스]${NC}"
  get_instances_status

  echo -e "\n${YELLOW}[RDS Proxy]${NC} $PROXY_NAME"
  if proxy_exists; then
    echo -e "  ${GREEN}존재함 ($(get_proxy_status)) — \$0.03/hr 과금 중${NC}"
  else
    echo -e "  ${CYAN}없음 — 과금 없음${NC}"
  fi
  echo ""
}

stop_cmd() {
  echo -e "\n${YELLOW}====== RDS 전체 중지 ======${NC}"
  echo -e "  1. RDS Proxy 삭제     → 과금 즉시 중단"
  echo -e "  2. Aurora 클러스터 중지 → 스토리지만 과금"
  echo ""
  read -p "진행하시겠습니까? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "취소"; exit 0; }

  # 1. Proxy 삭제
  if proxy_exists; then
    echo -e "\n${YELLOW}[1/2] Proxy 삭제 중...${NC}"
    aws rds delete-db-proxy \
      --db-proxy-name "$PROXY_NAME" \
      --region "$REGION" --output text > /dev/null
    wait_proxy_deleted
    # (by 김다정, 2026.06.01) Proxy 삭제 시 Reader Endpoint(aws-rds-proxy-01-reader)도 AWS에서 자동 삭제됨
  else
    echo -e "\n${CYAN}[1/2] Proxy 없음 — 건너뜀${NC}"
  fi

  # 2. 클러스터 중지
  local cs=$(get_cluster_status)
  if [ "$cs" = "stopped" ]; then
    echo -e "\n${CYAN}[2/2] 클러스터 이미 중지됨${NC}"
  elif [ "$cs" = "available" ]; then
    echo -e "\n${YELLOW}[2/2] 클러스터 중지 중...${NC}"
    aws rds stop-db-cluster \
      --db-cluster-identifier "$CLUSTER_ID" \
      --region "$REGION" --output text > /dev/null
    wait_for_cluster "stopped"
  else
    echo -e "${RED}클러스터 상태 '$cs' — 중지 불가${NC}"; exit 1
  fi

  echo -e "\n${GREEN}====== 중지 완료 ======${NC}"
  echo -e "  클러스터: 스토리지만 과금 (~\$0.10/GB/월)"
  echo -e "  Proxy:    삭제됨 — 과금 없음"
  echo -e "${RED}  ※ 7일 후 AWS 자동 재시작 주의${NC}\n"
}

start_cmd() {
  resolve_config

  echo -e "${YELLOW}====== RDS 전체 시작 ======${NC}"
  echo -e "  1. Aurora 클러스터 시작 (~3~5분)"
  echo -e "  2. RDS Proxy 재생성    (~5~10분)"
  echo ""

  # 1. 클러스터 시작
  local cs=$(get_cluster_status)
  if [ "$cs" = "available" ]; then
    echo -e "${CYAN}[1/2] 클러스터 이미 실행 중${NC}"
  elif [ "$cs" = "stopped" ]; then
    echo -e "${YELLOW}[1/2] 클러스터 시작 중...${NC}"
    aws rds start-db-cluster \
      --db-cluster-identifier "$CLUSTER_ID" \
      --region "$REGION" --output text > /dev/null
    wait_for_cluster "available"
  else
    echo -e "${RED}클러스터 상태 '$cs' — 시작 불가${NC}"; exit 1
  fi

  # 2. Proxy 재생성
  if proxy_exists; then
    echo -e "\n${CYAN}[2/2] Proxy 이미 존재함 — 건너뜀${NC}"
  else
    echo -e "\n${YELLOW}[2/2] Proxy 재생성 중...${NC}"
    aws rds create-db-proxy \
      --db-proxy-name "$PROXY_NAME" \
      --engine-family POSTGRESQL \
      --auth "[
        {\"AuthScheme\":\"SECRETS\",\"SecretArn\":\"$SECRET_ARN_HOSPITAL\",\"IAMAuth\":\"DISABLED\"},
        {\"AuthScheme\":\"SECRETS\",\"SecretArn\":\"$SECRET_ARN_API\",\"IAMAuth\":\"DISABLED\"}
      ]" \
      --role-arn "$PROXY_ROLE_ARN" \
      --vpc-subnet-ids $PROXY_SUBNET_IDS \
      --vpc-security-group-ids "$PROXY_SG_ID" \
      --require-tls \
      --idle-client-timeout 1800 \
      --region "$REGION" --output text > /dev/null

    wait_for_proxy "available"

    echo -e "${YELLOW}  Proxy → 클러스터 Target 연결 중...${NC}"
    aws rds register-db-proxy-targets \
      --db-proxy-name "$PROXY_NAME" \
      --db-cluster-identifiers "$CLUSTER_ID" \
      --region "$REGION" --output text > /dev/null
    echo -e "${GREEN}  Target 연결 완료${NC}"

    # (by 김다정, 2026.06.01) Reader Endpoint 재생성 — Proxy 재생성 시 함께 생성해야 함
    echo -e "${YELLOW}  Reader Endpoint 생성 중...${NC}"
    aws rds create-db-proxy-endpoint \
      --db-proxy-name "$PROXY_NAME" \
      --db-proxy-endpoint-name "$READER_ENDPOINT_NAME" \
      --vpc-subnet-ids $PROXY_SUBNET_IDS \
      --vpc-security-group-ids "$PROXY_SG_ID" \
      --target-role READ_ONLY \
      --region "$REGION" --output text > /dev/null
    wait_for_reader_endpoint

    # (by 김다정, 2026.06.01) 이 스크립트는 AWS CLI로 Proxy를 직접 생성하므로 Terraform state와 불일치 발생
    # start 완료 후 아래 명령으로 state 동기화 필요 (TC-aws-rds workspace에서 실행)
    #   terraform import aws_db_proxy.main aws-rds-proxy-01
    #   terraform import aws_db_proxy_default_target_group.main aws-rds-proxy-01
    #   terraform import 'aws_db_proxy_endpoint.reader' 'aws-rds-proxy-01/aws-rds-proxy-01-reader'
  fi

  echo -e "\n${GREEN}====== 시작 완료 ======${NC}\n${CYAN}[접속 정보]${NC}"
  aws rds describe-db-clusters \
    --db-cluster-identifier "$CLUSTER_ID" \
    --region "$REGION" \
    --query 'DBClusters[0].{Writer:Endpoint,Reader:ReaderEndpoint,Port:Port}' \
    --output table

  if proxy_exists; then
    local pe=$(aws rds describe-db-proxies \
      --db-proxy-name "$PROXY_NAME" \
      --region "$REGION" \
      --query 'DBProxies[0].Endpoint' \
      --output text 2>/dev/null)
    echo -e "  Proxy Writer: ${GREEN}$pe${NC}"
    # (by 김다정, 2026.06.01) Reader Endpoint URL 출력 추가
    local re=$(aws rds describe-db-proxy-endpoints \
      --db-proxy-name "$PROXY_NAME" \
      --db-proxy-endpoint-name "$READER_ENDPOINT_NAME" \
      --region "$REGION" \
      --query 'DBProxyEndpoints[0].Endpoint' \
      --output text 2>/dev/null)
    [ -n "$re" ] && [ "$re" != "None" ] && echo -e "  Proxy Reader: ${GREEN}$re${NC}"
  fi
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
    echo -e "  ${GREEN}stop${NC}   — Proxy 삭제 + 클러스터 중지 (비용 완전 절감)"
    echo -e "  ${GREEN}start${NC}  — 클러스터 시작 + Proxy 재생성 (실습 전)"
    echo -e "  ${GREEN}status${NC} — 현재 상태 확인"
    echo ""
    exit 1
    ;;
esac
