#!/bin/bash
# ================================================================
# hospital-ecs-toggle.sh
# ECS 클러스터 + EC2 ASG 통합 관리 스크립트 (dev 환경)
#
# 사용법:
#   ./hospital-ecs-toggle.sh stop    # 서비스 종료 + EC2 중단
#   ./hospital-ecs-toggle.sh start   # EC2 재시작 + 서비스 복구
#   ./hospital-ecs-toggle.sh status  # 현재 상태 확인
#
# 중지 순서:
#   1. ECS 서비스 desired=0 (태스크 드레인)
#   2. ASG 프로세스 일시 중단 (중단된 인스턴스 자동 교체 방지)
#   3. EC2 인스턴스 stop (terminate 아님)
#
# 시작 순서:
#   1. EC2 인스턴스 start
#   2. ASG 프로세스 재개
#   3. ECS 클러스터 등록 대기
#   4. ECS 서비스 desired=2 복구
# ================================================================

REGION="ap-south-2"
ECS_CLUSTER="aws-ecs-cluster-01"
ASG_NAME="aws-ecs-asg-01"
ASG_MIN=2
ASG_MAX=3
ASG_DESIRED=2

SERVICES=("patient-service" "staff-service")
SERVICE_DESIRED=2

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
  if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}[ERROR] AWS 자격증명이 설정되어 있지 않습니다. aws configure 를 먼저 실행하세요.${NC}"
    exit 1
  fi
}

# ── 상태 조회 함수 ─────────────────────────────────────────────
get_service_counts() {
  local svc=$1
  aws ecs describe-services \
    --cluster "$ECS_CLUSTER" \
    --services "$svc" \
    --region "$REGION" \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' \
    --output text 2>/dev/null
}

get_asg_instance_ids() {
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
    --output text 2>/dev/null
}

get_ec2_state() {
  local instance_id=$1
  aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null
}

get_ecs_registered_count() {
  aws ecs list-container-instances \
    --cluster "$ECS_CLUSTER" \
    --region "$REGION" \
    --query 'length(containerInstanceArns)' \
    --output text 2>/dev/null
}

get_all_running_tasks() {
  local total=0
  for svc in "${SERVICES[@]}"; do
    local running
    running=$(get_service_counts "$svc" | awk '{print $2}')
    total=$((total + ${running:-0}))
  done
  echo $total
}

get_asg_suspended_processes() {
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].SuspendedProcesses[*].ProcessName' \
    --output text 2>/dev/null
}

get_warm_pool_instances() {
  aws autoscaling describe-warm-pool \
    --auto-scaling-group-name "$ASG_NAME" \
    --region "$REGION" \
    --query 'Instances[*].[InstanceId,LifecycleState]' \
    --output text 2>/dev/null
}

# ── 대기 함수 ──────────────────────────────────────────────────
wait_tasks_drained() {
  local elapsed=0
  echo -e "${CYAN}  태스크 드레인 대기 중...${NC}"
  while [ $elapsed -lt 300 ]; do
    local total
    total=$(get_all_running_tasks)
    echo -e "  [$(date +%H:%M:%S)] 실행 중 태스크: ${total}개"
    [ "$total" -eq 0 ] && echo -e "${GREEN}  모든 태스크 종료 완료${NC}" && return 0
    sleep 15; elapsed=$((elapsed+15))
  done
  echo -e "${RED}  타임아웃 — 태스크가 남아있습니다.${NC}"; return 1
}

wait_instances_stopped() {
  local instance_ids=("$@")
  local elapsed=0
  echo -e "${CYAN}  EC2 인스턴스 중단 대기 중...${NC}"
  while [ $elapsed -lt 300 ]; do
    local all_stopped=true
    for id in "${instance_ids[@]}"; do
      local state
      state=$(get_ec2_state "$id")
      [ "$state" != "stopped" ] && all_stopped=false && break
    done
    echo -e "  [$(date +%H:%M:%S)] 상태 확인 중..."
    $all_stopped && echo -e "${GREEN}  모든 인스턴스 중단 완료${NC}" && return 0
    sleep 15; elapsed=$((elapsed+15))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

wait_instances_running() {
  local instance_ids=("$@")
  local elapsed=0
  echo -e "${CYAN}  EC2 인스턴스 재시작 대기 중...${NC}"
  while [ $elapsed -lt 300 ]; do
    local all_running=true
    for id in "${instance_ids[@]}"; do
      local state
      state=$(get_ec2_state "$id")
      [ "$state" != "running" ] && all_running=false && break
    done
    echo -e "  [$(date +%H:%M:%S)] 상태 확인 중..."
    $all_running && echo -e "${GREEN}  모든 인스턴스 running 상태${NC}" && return 0
    sleep 15; elapsed=$((elapsed+15))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

wait_ecs_registered() {
  local target=$1
  local elapsed=0
  echo -e "${CYAN}  ECS 클러스터 등록 대기 중 (목표: ${target}대)...${NC}"
  while [ $elapsed -lt 300 ]; do
    local registered
    registered=$(get_ecs_registered_count)
    echo -e "  [$(date +%H:%M:%S)] ECS 등록 인스턴스: ${registered:-0}대"
    [ "${registered:-0}" -ge "$target" ] && echo -e "${GREEN}  ECS 등록 완료${NC}" && return 0
    sleep 15; elapsed=$((elapsed+15))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

# ── status ─────────────────────────────────────────────────────
status_cmd() {
  echo -e "\n${CYAN}====== ECS 리소스 현재 상태 ======${NC}"

  echo -e "\n${YELLOW}[ECS 서비스]${NC} 클러스터: $ECS_CLUSTER"
  printf "  %-20s %8s %8s %8s\n" "서비스명" "Desired" "Running" "Pending"
  printf "  %-20s %8s %8s %8s\n" "--------------------" "-------" "-------" "-------"
  for svc in "${SERVICES[@]}"; do
    local counts
    counts=$(get_service_counts "$svc")
    if [ -z "$counts" ]; then
      printf "  %-20s %8s\n" "$svc" "조회 실패"
    else
      local desired running pending
      desired=$(echo "$counts" | awk '{print $1}')
      running=$(echo "$counts" | awk '{print $2}')
      pending=$(echo "$counts" | awk '{print $3}')
      local color=$NC
      [ "${running:-0}" -eq 0 ] && color=$CYAN
      [ "${running:-0}" -gt 0 ] && color=$GREEN
      printf "  ${color}%-20s %8s %8s %8s${NC}\n" "$svc" "$desired" "$running" "$pending"
    fi
  done

  echo -e "\n${YELLOW}[EC2 인스턴스]${NC} ASG: $ASG_NAME"
  local ids
  ids=$(get_asg_instance_ids)
  if [ -z "$ids" ]; then
    echo -e "  ${CYAN}인스턴스 없음${NC}"
  else
    for id in $ids; do
      local state
      state=$(get_ec2_state "$id")
      local color=$NC
      [ "$state" = "running" ] && color=$GREEN
      [ "$state" = "stopped" ] && color=$CYAN
      echo -e "  ${color}$id  —  $state${NC}"
    done
  fi

  local registered
  registered=$(get_ecs_registered_count)
  echo -e "\n${YELLOW}[ECS 등록 인스턴스]${NC} ${registered:-0}대"

  local suspended
  suspended=$(get_asg_suspended_processes)
  if [ -n "$suspended" ] && [ "$suspended" != "None" ]; then
    echo -e "\n${YELLOW}[ASG 일시 중단 프로세스]${NC} $suspended"
  fi

  echo -e "\n${YELLOW}[Warm Pool]${NC} ASG: $ASG_NAME"
  local wp_instances
  wp_instances=$(get_warm_pool_instances)
  if [ -z "$wp_instances" ]; then
    echo -e "  ${CYAN}Warm Pool 인스턴스 없음${NC}"
  else
    while IFS=$'\t' read -r wp_id wp_state; do
      local color=$NC
      [ "$wp_state" = "Warmed:Stopped" ] && color=$CYAN
      [ "$wp_state" = "Warmed:Running" ] && color=$GREEN
      echo -e "  ${color}$wp_id  —  $wp_state${NC}"
    done <<< "$wp_instances"
  fi
  echo ""
}

# ── stop ───────────────────────────────────────────────────────
stop_cmd() {
  echo -e "\n${YELLOW}====== ECS 클러스터 전체 중단 ======${NC}"
  echo -e "  1. ECS 서비스 desired=0  → 태스크 드레인"
  echo -e "  2. ASG 프로세스 일시 중단 → 인스턴스 자동 교체 방지"
  echo -e "  3. EC2 인스턴스 stop      → 컴퓨팅 비용 절감 (EBS만 과금)"
  echo -e "  4. ASG min=0, desired=0  → 콘솔에서 명시적으로 비활성 표시"
  echo ""
  read -p "진행하시겠습니까? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "취소"; exit 0; }

  # 1. 서비스 desired=0
  echo -e "\n${YELLOW}[1/4] ECS 서비스 종료 중...${NC}"
  for svc in "${SERVICES[@]}"; do
    local current
    current=$(get_service_counts "$svc" | awk '{print $1}')
    if [ "${current:-0}" -eq 0 ]; then
      echo -e "  ${CYAN}$svc — 이미 desired=0, 건너뜀${NC}"
    else
      echo -e "  $svc → desired=0 설정 중..."
      aws ecs update-service \
        --cluster "$ECS_CLUSTER" \
        --service "$svc" \
        --desired-count 0 \
        --region "$REGION" \
        --output text --query 'service.desiredCount' > /dev/null
      echo -e "  ${GREEN}$svc — 완료${NC}"
    fi
  done

  wait_tasks_drained

  # 2. ASG 프로세스 일시 중단 (중단된 인스턴스를 비정상으로 판단해 교체하는 것 방지)
  echo -e "\n${YELLOW}[2/4] ASG 프로세스 일시 중단 중...${NC}"
  aws autoscaling suspend-processes \
    --auto-scaling-group-name "$ASG_NAME" \
    --scaling-processes Launch Terminate HealthCheck ReplaceUnhealthy \
    --region "$REGION"
  echo -e "  ${GREEN}완료 (Launch / Terminate / HealthCheck / ReplaceUnhealthy 중단)${NC}"

  # 3. EC2 인스턴스 stop
  echo -e "\n${YELLOW}[3/4] EC2 인스턴스 중단 중...${NC}"
  local ids
  ids=$(get_asg_instance_ids)
  if [ -z "$ids" ]; then
    echo -e "  ${CYAN}실행 중인 인스턴스 없음 — 건너뜀${NC}"
  else
    local id_array=($ids)
    echo -e "  대상 인스턴스: ${id_array[*]}"
    aws ec2 stop-instances \
      --instance-ids "${id_array[@]}" \
      --region "$REGION" \
      --output text > /dev/null
    wait_instances_stopped "${id_array[@]}"
  fi

  # 4. ASG min=0, desired=0 (프로세스가 이미 suspended라 terminate 안 됨)
  echo -e "\n${YELLOW}[4/4] ASG 용량 초기화 중 (min=0, desired=0)...${NC}"
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --min-size 0 \
    --desired-capacity 0 \
    --region "$REGION"
  echo -e "  ${GREEN}완료${NC}"

  echo -e "\n${GREEN}====== 중단 완료 ======${NC}"
  echo -e "  ECS 서비스: 모든 태스크 종료"
  echo -e "  EC2 인스턴스: 중단됨 (terminated 아님)"
  echo -e "  ASG: min=0, desired=0"
  echo -e "${YELLOW}  ※ start 전까지 ASG 자동 복구 기능이 비활성화되어 있습니다.${NC}\n"
}

# ── start ──────────────────────────────────────────────────────
start_cmd() {
  echo -e "\n${YELLOW}====== ECS 클러스터 전체 시작 ======${NC}"
  echo -e "  1. ASG min=$ASG_MIN, desired=$ASG_DESIRED 복구"
  echo -e "  2. EC2 인스턴스 start     (~1~2분)"
  echo -e "  3. ASG 프로세스 재개"
  echo -e "  4. ECS 클러스터 등록 대기"
  echo -e "  5. ECS 서비스 desired=$SERVICE_DESIRED 복구"
  echo ""

  # 1. ASG min/desired 복구 (프로세스가 suspended 상태라 auto-launch 안 됨)
  echo -e "${YELLOW}[1/5] ASG 용량 복구 중 (min=$ASG_MIN, desired=$ASG_DESIRED)...${NC}"
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --min-size "$ASG_MIN" \
    --max-size "$ASG_MAX" \
    --desired-capacity "$ASG_DESIRED" \
    --region "$REGION"
  echo -e "  ${GREEN}완료${NC}"

  # 2. EC2 인스턴스 start
  echo -e "\n${YELLOW}[2/5] EC2 인스턴스 시작 중...${NC}"
  local ids
  ids=$(get_asg_instance_ids)
  if [ -z "$ids" ]; then
    echo -e "  ${RED}ASG에 인스턴스가 없습니다. 인스턴스 상태를 확인하세요.${NC}"
    exit 1
  fi

  local id_array=($ids)
  local stopped_ids=()
  for id in "${id_array[@]}"; do
    local state
    state=$(get_ec2_state "$id")
    if [ "$state" = "stopped" ]; then
      stopped_ids+=("$id")
    elif [ "$state" = "running" ]; then
      echo -e "  ${CYAN}$id — 이미 running, 건너뜀${NC}"
    fi
  done

  if [ ${#stopped_ids[@]} -gt 0 ]; then
    echo -e "  시작 대상: ${stopped_ids[*]}"
    aws ec2 start-instances \
      --instance-ids "${stopped_ids[@]}" \
      --region "$REGION" \
      --output text > /dev/null
    wait_instances_running "${id_array[@]}"
  else
    echo -e "  ${CYAN}모든 인스턴스가 이미 running 상태${NC}"
  fi

  # 3. ASG 프로세스 재개
  echo -e "\n${YELLOW}[3/5] ASG 프로세스 재개 중...${NC}"
  aws autoscaling resume-processes \
    --auto-scaling-group-name "$ASG_NAME" \
    --scaling-processes Launch Terminate HealthCheck ReplaceUnhealthy \
    --region "$REGION"
  echo -e "  ${GREEN}완료${NC}"

  # 4. ECS 등록 대기
  echo -e "\n${YELLOW}[4/5] ECS 클러스터 등록 대기...${NC}"
  wait_ecs_registered "${#id_array[@]}"

  # 5. 서비스 복구
  echo -e "\n${YELLOW}[5/5] ECS 서비스 복구 중...${NC}"
  for svc in "${SERVICES[@]}"; do
    local current
    current=$(get_service_counts "$svc" | awk '{print $1}')
    if [ "${current:-0}" -ge "$SERVICE_DESIRED" ]; then
      echo -e "  ${CYAN}$svc — 이미 desired=${current}, 건너뜀${NC}"
    else
      echo -e "  $svc → desired=$SERVICE_DESIRED 설정 중..."
      aws ecs update-service \
        --cluster "$ECS_CLUSTER" \
        --service "$svc" \
        --desired-count "$SERVICE_DESIRED" \
        --region "$REGION" \
        --output text --query 'service.desiredCount' > /dev/null
      echo -e "  ${GREEN}$svc — 완료${NC}"
    fi
  done

  echo -e "\n${GREEN}====== 시작 완료 ======${NC}"
  echo -e "  EC2 인스턴스: running 상태"
  echo -e "  ECS 서비스: desired=$SERVICE_DESIRED 복구됨"
  echo -e "${CYAN}  ※ 태스크 배포까지 2~3분 추가 소요됩니다.${NC}\n"
  status_cmd
}

# ── 메인 ──────────────────────────────────────────────────────
check_aws_cli

case "$1" in
  stop)   stop_cmd ;;
  start)  start_cmd ;;
  status) status_cmd ;;
  *)
    echo ""
    echo -e "  사용법: $0 {stop|start|status}"
    echo ""
    echo -e "  ${GREEN}stop${NC}   — 서비스 종료 + EC2 인스턴스 중단 (EBS만 과금)"
    echo -e "  ${GREEN}start${NC}  — EC2 재시작 + 서비스 복구 (~3~5분)"
    echo -e "  ${GREEN}status${NC} — 현재 상태 확인 (ECS / EC2 / Warm Pool)"
    echo ""
    exit 1
    ;;
esac
