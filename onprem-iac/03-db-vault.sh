#!/usr/bin/env bash
# =============================================================================
# 03-db-vault.sh — PostgreSQL + HashiCorp Vault 컨테이너 초기화
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "root 권한으로 실행하세요: sudo $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

_require_var() {
    local var="$1" prompt="$2"
    if [[ -z "${!var:-}" ]]; then read -rsp "${prompt}: " "$var"; echo; fi
    [[ -z "${!var:-}" ]] && err "$var 가 비어 있습니다."
    # placeholder 미교체 감지
    [[ "${!var}" =~ ^__.*__$ ]] && err "$var 가 템플릿 placeholder 그대로입니다. 실제 값으로 교체하세요."
}

_require_var POSTGRES_PASSWORD     "PostgreSQL postgres 슈퍼유저 비밀번호"
_require_var AWS_ACCESS_KEY_ID     "AWS Access Key ID"
_require_var AWS_SECRET_ACCESS_KEY "AWS Secret Access Key"
_require_var AWS_REGION            "AWS Region (예: ap-south-2)"
_require_var KMS_KEY_ID            "KMS Key ID (Vault auto-unseal)"
_require_var ONPREM_PRIVATE_IP     "온프레미스 사설 IP (예: 172.30.1.76)"

log "=== 03-db-vault.sh 시작 ==="

# ── 1. Docker 네트워크 ────────────────────────────────────────────────────────
log "[1/7] Docker 네트워크 생성"
if ! docker network inspect hospital-net &>/dev/null; then
    docker network create hospital-net && log "hospital-net 생성"
else
    warn "hospital-net 이미 존재"
fi

# ── 2. 디렉토리 ───────────────────────────────────────────────────────────────
log "[2/7] 데이터 디렉토리 준비"
mkdir -p /opt/hospital/postgres/data
mkdir -p /opt/hospital/vault/data /opt/hospital/vault/config /opt/hospital/vault/logs
chmod 700 /opt/hospital/postgres/data /opt/hospital/vault/data

# ── 3. Vault 설정 ─────────────────────────────────────────────────────────────
log "[3/7] Vault 설정 파일 작성"
cat > /opt/hospital/vault/config/vault.hcl <<EOF
ui = false
storage "file" { path = "/vault/data" }

# 내부망(VPN) 전용 — TLS는 VPN 터널에 위임
# TODO: 운영 전환 시 TLS 적용 및 tls_disable 제거
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

seal "awskms" {
  region     = "${AWS_REGION}"
  kms_key_id = "${KMS_KEY_ID}"
}

api_addr     = "http://${ONPREM_PRIVATE_IP}:8200"
cluster_addr = "http://${ONPREM_PRIVATE_IP}:8201"
log_level    = "info"
EOF

# ── 4. PostgreSQL 컨테이너 ────────────────────────────────────────────────────
log "[4/7] hospital_db (postgres:17.9) 실행"
if docker ps -a --format '{{.Names}}' | grep -q '^hospital_db$'; then
    warn "hospital_db 이미 존재 — 재시작"; docker rm -f hospital_db
fi

docker run -d \
    --name hospital_db \
    --network hospital-net \
    --restart unless-stopped \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB=hospital \
    -v /opt/hospital/postgres/data:/var/lib/postgresql/data \
    -p 127.0.0.1:5432:5432 \
    postgres:17.9

log "PostgreSQL 기동 대기 (최대 30초)..."
for i in $(seq 1 30); do
    docker exec hospital_db pg_isready -U postgres &>/dev/null && {
        log "PostgreSQL 준비 완료 (${i}초)"; break
    }
    sleep 1; [[ $i -eq 30 ]] && err "PostgreSQL 30초 내 기동 실패"
done

# ── 5. PostgreSQL DB roles ────────────────────────────────────────────────────
log "[5/7] PostgreSQL DB roles 생성"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
    psql -U postgres -d hospital << 'SQL'
-- RLS policy의 TO <role> 이 참조하는 PostgreSQL DB role
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='role_admin')   THEN CREATE ROLE role_admin;   END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='role_doctor')  THEN CREATE ROLE role_doctor;  END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='role_nurse')   THEN CREATE ROLE role_nurse;   END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='role_patient') THEN CREATE ROLE role_patient; END IF;
END $$;

-- api_user: Vault dynamic credential의 부모 역할 (NOLOGIN)
-- ※ role_* 를 여기서 GRANT하지 않음
--   → 상속 시 patients_admin USING(true) 등이 전파되어 RLS 무력화 위험
--   → dynamic role 생성 시 GRANT ... WITH INHERIT FALSE 로 전환 권한만 부여
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='api_user') THEN
        CREATE ROLE api_user NOLOGIN;
    END IF;
END $$;
SQL
log "DB roles 생성 완료 (role_* → api_user GRANT 없음, INHERIT FALSE 방식 사용)"

# ── 6. Vault 컨테이너 ─────────────────────────────────────────────────────────
log "[6/7] hospital_vault (hashicorp/vault:1.17) 실행"
if docker ps -a --format '{{.Names}}' | grep -q '^hospital_vault$'; then
    warn "hospital_vault 이미 존재 — 재시작"; docker rm -f hospital_vault
fi

docker run -d \
    --name hospital_vault \
    --network hospital-net \
    --restart unless-stopped \
    --cap-add IPC_LOCK \
    -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
    -e AWS_REGION="${AWS_REGION}" \
    -v /opt/hospital/vault/data:/vault/data \
    -v /opt/hospital/vault/config:/vault/config \
    -v /opt/hospital/vault/logs:/vault/logs \
    -p "${ONPREM_PRIVATE_IP}:8200:8200" \
    hashicorp/vault:1.17 \
    vault server -config=/vault/config/vault.hcl

log "Vault 기동 대기 (최대 30초)..."
for i in $(seq 1 30); do
    STATUS=$(docker exec hospital_vault \
        sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null | jq -r .initialized' \
        2>/dev/null || echo "waiting")
    [[ "$STATUS" == "false" || "$STATUS" == "true" ]] && {
        log "Vault 응답 확인 (${i}초)"; break
    }
    sleep 1; [[ $i -eq 30 ]] && err "Vault 30초 내 응답 없음"
done

VAULT_INITIALIZED=$(docker exec hospital_vault \
    sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null | jq -r .initialized' \
    2>/dev/null || echo "false")

if [[ "$VAULT_INITIALIZED" == "false" ]]; then
    log "Vault 초기화 (AWS KMS auto-unseal)"
    docker exec hospital_vault \
        sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault operator init \
            -recovery-shares=5 -recovery-threshold=3 -format=json' \
        > /opt/hospital/vault/vault-init-output.json
    chmod 600 /opt/hospital/vault/vault-init-output.json
    log "Vault 초기화 완료"
    warn "루트 토큰 → /opt/hospital/vault/vault-init-output.json"
    warn "Recovery Key 안전한 곳에 백업 후 파일 삭제 권장"
    warn "→ .env 에 VAULT_ROOT_TOKEN 추가 후 03.5-vault-bootstrap.sh 실행"
else
    warn "Vault 이미 초기화됨"
fi

# ── 7. 검증 ───────────────────────────────────────────────────────────────────
log "[7/7] 컨테이너 상태"
docker ps --filter "name=hospital_db" --filter "name=hospital_vault" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
docker exec hospital_vault sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status' 2>/dev/null \
    || warn "Vault 상태 확인 실패"
log "=== 03-db-vault.sh 완료 ==="
