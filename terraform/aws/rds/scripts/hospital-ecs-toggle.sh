#!/bin/bash
# ================================================================
# hospital-ecs-toggle.sh
# ECS 클러스터 + EC2 ASG 통합 관리 스크립트
#
# 사용법:
#   ./hospital-ecs-toggle.sh stop    # 서비스 종료 + EC2 인스턴스 종료
#   ./hospital-ecs-toggle.sh start   # EC2 기동 + 서비스 복구
#   ./hospital-ecs-toggle.sh status  # 현재 상태 확인
#
# 중지 순서:
#   1. ECS 서비스 desired=0 (태스크 드레인)
#   2. Warm Pool min=0 (Stopped 인스턴스 제거)
#   3. ASG 스케일링 프로세스 정지 (Launch 등 — EC2 자동 복구 차단)
#   4. ASG min=0 → EC2 인스턴스 종료 대기
#
# 시작 순서:
#   1. ASG 스케일링 프로세스 재개
#   2. Warm Pool 복원
#   3. ASG min=2 → EC2 기동 대기
#   4. ECS 서비스 desired=2 복구
# ================================================================

REGION="ap-south-2"
ECS_CLUSTER="aws-ecs-cluster-01"
ASG_NAME="aws-ecs-asg-01"

SERVICES=("patient-service" "staff-service")
SERVICE_DESIRED=2

ASG_MIN_RESTORE=2
ASG_MAX_RESTORE=3

WP_MIN_RESTORE=1
WP_MAX_RESTORE=2

# stop 시 정지할 ASG 프로세스 (Launch: 신규 인스턴스 기동 차단이 핵심)
ASG_SUSPEND_PROCESSES="Launch ReplaceUnhealthy AZRebalance ScheduledActions"

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

get_asg_info() {
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Running:Instances[?LifecycleState==`InService`]|length(@)}' \
    --output text 2>/dev/null
}

get_asg_instance_ids() {
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
    --output text 2>/dev/null
}

get_asg_suspended_processes() {
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].SuspendedProcesses[*].ProcessName' \
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
    local counts
    counts=$(get_service_counts "$svc")
    local running
    running=$(echo "$counts" | awk '{print $2}')
    total=$((total + ${running:-0}))
  done
  echo $total
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

wait_instances_terminated() {
  local elapsed=0
  echo -e "${CYAN}  EC2 인스턴스 종료 대기 중...${NC}"
  while [ $elapsed -lt 600 ]; do
    local ids
    ids=$(get_asg_instance_ids)
    local count=0
    [ -n "$ids" ] && count=$(echo "$ids" | wc -w | tr -d ' ')
    echo -e "  [$(date +%H:%M:%S)] InService 인스턴스: ${count}대"
    [ "$count" -eq 0 ] && echo -e "${GREEN}  모든 인스턴스 종료 완료${NC}" && return 0
    sleep 20; elapsed=$((elapsed+20))
  done
  echo -e "${RED}  타임아웃${NC}"; return 1
}

wait_instances_ready() {
  local target=$1
  local elapsed=0
  echo -e "${CYAN}  EC2 인스턴스 기동 대기 중 (목표: ${target}대)...${NC}"
  while [ $elapsed -lt 600 ]; do
    local ids
    ids=$(get_asg_instance_ids)
    local count=0
    [ -n "$ids" ] && count=$(echo "$ids" | wc -w | tr -d ' ')
    local registered
    registered=$(get_ecs_registered_count)
    echo -e "  [$(date +%H:%M:%S)] InService: ${count}대 / ECS 등록: ${registered:-0}대"
    [ "${registered:-0}" -ge "$target" ] && echo -e "${GREEN}  ECS 등록 완료${NC}" && return 0
    sleep 20; elapsed=$((elapsed+20))
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
      local status_color=$NC
      [ "$running" -eq 0 ] && status_color=$CYAN
      [ "$running" -gt 0 ] && status_color=$GREEN
      printf "  ${status_color}%-20s %8s %8s %8s${NC}\n" "$svc" "$desired" "$running" "$pending"
    fi
  done

  echo -e "\n${YELLOW}[Auto Scaling Group]${NC} $ASG_NAME"
  local asg_info
  asg_info=$(get_asg_info)
  if [ -z "$asg_info" ]; then
    echo -e "  ${RED}ASG 조회 실패${NC}"
  else
    local min max desired running
    min=$(echo "$asg_info" | awk '{print $1}')
    max=$(echo "$asg_info" | awk '{print $2}')
    desired=$(echo "$asg_info" | awk '{print $3}')
    running=$(echo "$asg_info" | awk '{print $4}')
    if [ "${running:-0}" -gt 0 ]; then
      echo -e "  ${GREEN}▶ 실행 중 — min=$min / desired=$desired / max=$max / InService=${running}대${NC}"
    else
      echo -e "  ${CYAN}■ 중지됨 — min=$min / desired=$desired / max=$max${NC}"
    fi
  fi

  local suspended
  suspended=$(get_asg_suspended_processes)
  if [ -n "$suspended" ]; then
    echo -e "  ${YELLOW}⚠ 정지된 프로세스: $suspended${NC}"
  else
    echo -e "  ${GREEN}  스케일링 프로세스: 정상 동작 중${NC}"
  fi

  local registered
  registered=$(get_ecs_registered_count)
  echo -e "\n${YELLOW}[ECS 등록 인스턴스]${NC} ${registered:-0}대"
  echo ""
}

# ── stop ───────────────────────────────────────────────────────
stop_cmd() {
  echo -e "\n${YELLOW}====== ECS 클러스터 전체 중지 ======${NC}"
  echo -e "  1. ECS 서비스 desired=0   → 태스크 드레인"
  echo -e "  2. Warm Pool 비우기       → Stopped 인스턴스 제거"
  echo -e "  3. ASG 프로세스 정지      → EC2 자동 복구 차단 (Launch 등)"
  echo -e "  4. ASG min=0              → EC2 인스턴스 종료"
  echo ""
  read -p "진행하시겠습니까? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "취소"; exit 0; }

  # 1. 서비스 desired=0
  echo -e "\n${YELLOW}[1/4] ECS 서비스 종료 중...${NC}"
  for svc in "${SERVICES[@]}"; do
    local current_desired
    current_desired=$(get_service_counts "$svc" | awk '{print $1}')
    if [ "${current_desired:-0}" -eq 0 ]; then
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

  # 2. 태스크 드레인 대기
  echo -e "\n${YELLOW}[2/4] 태스크 드레인 대기...${NC}"
  wait_tasks_drained

  # 3. Warm Pool 비우기
  echo -e "\n${YELLOW}[3/4] Warm Pool 비우기 + ASG 프로세스 정지...${NC}"
  local wp_config
  wp_config=$(aws autoscaling describe-warm-pool \
    --auto-scaling-group-name "$ASG_NAME" \
    --region "$REGION" \
    --query 'WarmPoolConfiguration.PoolState' \
    --output text 2>/dev/null)
  if [ -n "$wp_config" ] && [ "$wp_config" != "None" ]; then
    aws autoscaling put-warm-pool \
      --auto-scaling-group-name "$ASG_NAME" \
      --min-size 0 \
      --max-group-prepared-capacity 0 \
      --region "$REGION" 2>/dev/null && \
      echo -e "  ${GREEN}Warm Pool min=0 설정 완료${NC}" || true
  else
    echo -e "  ${CYAN}Warm Pool 없음 — 건너뜀${NC}"
  fi

  # ASG 스케일링 프로세스 정지 — Launch 정지가 핵심 (CP/헬스체크가 인스턴스를 되살리는 것 차단)
  echo -e "  ASG 스케일링 프로세스 정지 중: $ASG_SUSPEND_PROCESSES"
  aws autoscaling suspend-processes \
    --auto-scaling-group-name "$ASG_NAME" \
    --scaling-processes $ASG_SUSPEND_PROCESSES \
    --region "$REGION" && \
    echo -e "  ${GREEN}ASG 프로세스 정지 완료${NC}"

  # 4. ASG 스케일 다운
  echo -e "\n${YELLOW}[4/4] EC2 인스턴스 종료 중...${NC}"
  local current_ids
  current_ids=$(get_asg_instance_ids)
  if [ -z "$current_ids" ]; then
    echo -e "  ${CYAN}실행 중인 인스턴스 없음 — 건너뜀${NC}"
  else
    echo -e "  인스턴스 scale-in 보호 해제 중..."
    aws autoscaling set-instance-protection \
      --instance-ids $current_ids \
      --auto-scaling-group-name "$ASG_NAME" \
      --no-protected-from-scale-in \
      --region "$REGION" 2>/dev/null || true

    # Launch 정지 후 desired=0 직접 설정 — CP가 자동으로 내리길 기다리면 안 내리는 경우 있음
    echo -e "  ASG min=0 / desired=0 설정 중..."
    aws autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$ASG_NAME" \
      --min-size 0 \
      --desired-capacity 0 \
      --region "$REGION"

    wait_instances_terminated
  fi

  echo -e "\n${GREEN}====== 중지 완료 ======${NC}"
  echo -e "  ECS 서비스: 모든 태스크 종료"
  echo -e "  ASG 프로세스: 정지됨 (start 실행 전까지 EC2 자동 복구 없음)"
  echo -e "  EC2 인스턴스: 종료됨 — 컴퓨팅 및 EBS 비용 없음\n"
}

# ── start ──────────────────────────────────────────────────────
start_cmd() {
  echo -e "\n${YELLOW}====== ECS 클러스터 전체 시작 ======${NC}"
  echo -e "  1. ASG 프로세스 재개      → 스케일링 정상화"
  echo -e "  2. Warm Pool 복원         → min=$WP_MIN_RESTORE / max=$WP_MAX_RESTORE"
  echo -e "  3. ASG min=$ASG_MIN_RESTORE → EC2 기동 (~3~5분)"
  echo -e "  4. ECS 서비스 desired=$SERVICE_DESIRED 복구"
  echo ""

  # 1. ASG 스케일링 프로세스 재개
  echo -e "${YELLOW}[1/4] ASG 스케일링 프로세스 재개 중...${NC}"
  aws autoscaling resume-processes \
    --auto-scaling-group-name "$ASG_NAME" \
    --scaling-processes $ASG_SUSPEND_PROCESSES \
    --region "$REGION" && \
    echo -e "  ${GREEN}ASG 프로세스 재개 완료${NC}"

  # 2. Warm Pool 복원
  echo -e "\n${YELLOW}[2/4] Warm Pool 복원 중...${NC}"
  aws autoscaling put-warm-pool \
    --auto-scaling-group-name "$ASG_NAME" \
    --min-size "$WP_MIN_RESTORE" \
    --max-group-prepared-capacity "$WP_MAX_RESTORE" \
    --pool-state Stopped \
    --region "$REGION" 2>/dev/null && \
    echo -e "  ${GREEN}Warm Pool 복원 완료${NC}" || \
    echo -e "  ${CYAN}Warm Pool 복원 실패 (무시)${NC}"

  # 3. ASG 스케일 업
  local current_desired
  current_desired=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].DesiredCapacity' \
    --output text 2>/dev/null)

  if [ "${current_desired:-0}" -ge "$ASG_MIN_RESTORE" ]; then
    echo -e "${CYAN}[3/4] ASG 이미 실행 중 (desired=${current_desired}) — 건너뜀${NC}"
  else
    echo -e "${YELLOW}[3/4] EC2 인스턴스 기동 중...${NC}"
    aws autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$ASG_NAME" \
      --min-size "$ASG_MIN_RESTORE" \
      --max-size "$ASG_MAX_RESTORE" \
      --region "$REGION"
    echo -e "  ${GREEN}ASG 업데이트 완료 — 인스턴스 기동 중...${NC}"
  fi

  echo -e "\n${YELLOW}  ECS 클러스터 등록 대기...${NC}"
  wait_instances_ready "$ASG_MIN_RESTORE"

  # 4. 서비스 복구
  echo -e "\n${YELLOW}[4/4] ECS 서비스 복구 중...${NC}"
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
  echo -e "  EC2 인스턴스: ${ASG_MIN_RESTORE}대 기동 중"
  echo -e "  ECS 서비스: desired=${SERVICE_DESIRED} 설정됨"
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
    echo -e "  ${GREEN}stop${NC}   — 서비스 종료 + ASG 프로세스 정지 + EC2 종료"
    echo -e "  ${GREEN}start${NC}  — ASG 프로세스 재개 + EC2 기동 + 서비스 복구"
    echo -e "  ${GREEN}status${NC} — 현재 상태 확인 (ASG 정지 프로세스 포함)"
    echo ""
    exit 1
    ;;
esac
