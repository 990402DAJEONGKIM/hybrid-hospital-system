#!/usr/bin/env bash
# =============================================================================
# 03.5-vault-bootstrap.sh — Vault 초기 구성
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
    [[ "${!var}" =~ ^__.*__$ ]] && err "$var 가 placeholder 그대로입니다. 실제 값으로 교체하세요."
}

_require_var VAULT_ROOT_TOKEN    "Vault 루트 토큰"
_require_var INTERNAL_API_TOKEN  "내부 API 토큰"
_require_var JWT_SECRET_KEY      "JWT 시크릿 키 (현재)"
_require_var JWT_SECRET_KEY_PREV "JWT 시크릿 키 (이전, grace period)"
_require_var POSTGRES_PASSWORD   "PostgreSQL postgres 비밀번호"

V() {
    docker exec hospital_vault \
        sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault $*"
}

log "=== 03.5-vault-bootstrap.sh 시작 ==="

log "[1/4] Vault 상태 확인"
SEALED=$(docker exec hospital_vault \
    sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null | jq -r .sealed' \
    2>/dev/null || echo "true")
[[ "$SEALED" == "true" ]] && err "Vault sealed 상태 — KMS unseal 확인 필요"
log "Vault unsealed ✔"

log "[2/4] KV v2 활성화"
V "secrets enable -path=secret kv-v2" 2>/dev/null || warn "secret/ KV v2 이미 활성화됨"

log "[3/4] Vault Policies 작성"
V "policy write hospital-auth -" <<'POLICY'
path "database/creds/onprem-api-role" { capabilities = ["read"] }
path "database/creds/api-role"        { capabilities = ["read"] }
path "auth/token/renew-self"          { capabilities = ["update"] }
POLICY

V "policy write hospital-db -" <<'POLICY'
path "secret/data/hospital/postgres"  { capabilities = ["read"] }
path "secret/data/hospital/deident"   { capabilities = ["read"] }
path "database/creds/api-role"        { capabilities = ["read"] }
path "database/creds/onprem-api-role" { capabilities = ["read"] }
POLICY

V "policy write lambda-vault-policy -" <<'POLICY'
path "database/config/rds-hospital" { capabilities = ["create", "update", "read"] }
POLICY

log "[4/4] AppRole + KV 시크릿"
V "auth enable approle" 2>/dev/null || warn "approle 이미 활성화됨"

V "write auth/approle/role/hospital-app \
    token_policies='hospital-auth,hospital-db' \
    token_ttl=0 token_max_ttl=0"
V "write auth/approle/role/hospital-db \
    token_policies='hospital-db' \
    token_ttl=1h token_max_ttl=4h"
V "write auth/approle/role/lambda-role \
    token_policies='lambda-vault-policy' \
    token_ttl=5m token_max_ttl=10m"

V "kv put secret/hospital-auth \
    internal_api_token='${INTERNAL_API_TOKEN}' \
    jwt_secret_key='${JWT_SECRET_KEY}' \
    jwt_secret_key_previous='${JWT_SECRET_KEY_PREV}'"
V "kv put secret/hospital/postgres \
    username='postgres' \
    password='${POSTGRES_PASSWORD}'"

echo ""
ROLE_ID=$(V "read -field=role_id auth/approle/role/hospital-app/role-id")
echo "────────────────────────────────────────"
log "hospital-app role_id: ${ROLE_ID}"
echo "────────────────────────────────────────"
warn ".env 의 VAULT_ROLE_ID 를 위 값으로 업데이트하세요"

log "=== 03.5-vault-bootstrap.sh 완료 ==="
warn "다음: 06-db-schema-rls-seed.sh"
