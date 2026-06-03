#!/usr/bin/env bash
# =============================================================================
# 05-start.sh — 전체 서비스 시작 + 헬스체크
# 컨테이너 실행 순서:
#   1. hospital_db       (이미 실행 중이어야 함 — 03에서 기동)
#   2. hospital_vault    (이미 실행 중이어야 함 — 03에서 기동)
#   3. deidentification-api
#   4. deident-nginx
#   5. wazuh-agent
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "root 권한으로 실행하세요: sudo $0"

# ── 환경변수 로드 ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

_require_var() {
    local var="$1" prompt="$2"
    if [[ -z "${!var:-}" ]]; then read -rsp "${prompt}: " "$var"; echo; fi
    [[ -z "${!var:-}" ]] && err "$var 가 비어 있습니다."
    [[ "${!var}" =~ ^__.*__$ ]] && err "$var 가 placeholder 그대로입니다. 실제 값으로 교체하세요."
}

_require_var API_REPO_PATH     "deidentification-api 소스 경로"
_require_var WAZUH_MANAGER_IP  "Wazuh Manager IP (AWS 내부 IP)"
_require_var ONPREM_PRIVATE_IP "온프레미스 사설 IP (예: 172.30.1.76)"

log "=== 05-start.sh 시작 ==="

# ── 헬퍼: 컨테이너 헬스 대기 ─────────────────────────────────────────────────
_wait_healthy() {
    local name="$1" timeout="${2:-60}"
    log "${name} 헬스 대기 (최대 ${timeout}초)..."
    for i in $(seq 1 "$timeout"); do
        STATUS=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
        if [[ "$STATUS" == "running" ]]; then
            log "${name} 실행 중 (${i}초)"
            return 0
        fi
        sleep 1
    done
    err "${name} ${timeout}초 내 기동 실패"
}

# ── 1. DB / Vault 상태 확인 ───────────────────────────────────────────────────
log "[1/5] DB / Vault 상태 확인"
for c in hospital_db hospital_vault; do
    STATUS=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
    if [[ "$STATUS" != "running" ]]; then
        err "${c} 가 실행 중이 아닙니다. 먼저 03-db-vault.sh 를 실행하세요."
    fi
    log "${c}: running ✔"
done

# ── 2. deidentification-api 실행 ──────────────────────────────────────────────
log "[2/5] deidentification-api 실행"

if docker ps -a --format '{{.Names}}' | grep -q '^deidentification-api$'; then
    warn "deidentification-api 기존 컨테이너 제거 후 재시작"
    docker rm -f deidentification-api
fi

docker run -d \
    --name deidentification-api \
    --network hospital-net \
    --restart unless-stopped \
    --env-file "${API_REPO_PATH}/.env" \
    -v /opt/hospital/vault/config:/vault/config:ro \
    deidentification-api:latest

_wait_healthy deidentification-api 60

# ── 3. deident-nginx 실행 ────────────────────────────────────────────────────
log "[3/5] deident-nginx 실행"

if docker ps -a --format '{{.Names}}' | grep -q '^deident-nginx$'; then
    warn "deident-nginx 기존 컨테이너 제거 후 재시작"
    docker rm -f deident-nginx
fi

docker run -d \
    --name deident-nginx \
    --network hospital-net \
    --restart unless-stopped \
    -p "${ONPREM_PRIVATE_IP}:443:443" \
    -p "${ONPREM_PRIVATE_IP}:80:80" \
    -v /opt/hospital/nginx/conf.d:/etc/nginx/conf.d:ro \
    -v /opt/hospital/nginx/ssl:/etc/nginx/ssl:ro \
    -v /opt/hospital/nginx/html:/etc/nginx/html:ro \
    nginx:latest

_wait_healthy deident-nginx 30

# nginx 설정 문법 검증
docker exec deident-nginx nginx -t && log "nginx 설정 문법 OK" \
    || err "nginx 설정 문법 오류 — /opt/hospital/nginx/conf.d/hospital.conf 확인"

# ── 4. wazuh-agent 실행 ───────────────────────────────────────────────────────
log "[4/5] wazuh-agent 실행"

if docker ps -a --format '{{.Names}}' | grep -q '^wazuh-agent$'; then
    warn "wazuh-agent 기존 컨테이너 제거 후 재시작"
    docker rm -f wazuh-agent
fi

docker run -d \
    --name wazuh-agent \
    --network host \
    --restart unless-stopped \
    --pid host \
    --privileged \
    -e WAZUH_MANAGER="${WAZUH_MANAGER_IP}" \
    -e WAZUH_AGENT_NAME="onprem-hospital" \
    -v /var/log:/var/log:ro \
    -v /etc:/etc:ro \
    wazuh/wazuh-agent:4.14.5

_wait_healthy wazuh-agent 30

# ── 5. 전체 헬스체크 ──────────────────────────────────────────────────────────
log "[5/5] 전체 서비스 헬스체크"
echo ""
echo "════════════════════════════════════════"
printf "%-25s %-15s %s\n" "컨테이너" "상태" "헬스"
echo "────────────────────────────────────────"

for c in hospital_db hospital_vault deidentification-api deident-nginx wazuh-agent; do
    STATUS=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
    if [[ "$STATUS" == "running" ]]; then
        printf "%-25s ${GREEN}%-15s${NC} %s\n" "$c" "running" "✔"
    else
        printf "%-25s ${RED}%-15s${NC} %s\n" "$c" "$STATUS" "✘"
    fi
done

echo "════════════════════════════════════════"

# nginx 엔드포인트 확인
log "nginx /health 엔드포인트 확인"
sleep 2
curl -sk "https://${ONPREM_PRIVATE_IP}/health" \
    && echo "" && log "nginx 응답 OK" \
    || warn "nginx /health 응답 없음 — 로그 확인: docker logs deident-nginx"

log "=== 05-start.sh 완료 ==="
warn "전체 IaC 설치 완료. 다음: role별 RLS smoke test를 실행하세요."
