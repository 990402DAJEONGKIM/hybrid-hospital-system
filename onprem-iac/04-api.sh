#!/usr/bin/env bash
# =============================================================================
# 04-api.sh — deidentification-api .env 생성 + SSL 인증서 + nginx 설정 + 이미지 빌드
# 전제: 03.5-vault-bootstrap.sh 완료 (KV 시크릿이 존재해야 함)
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

_require_var VAULT_ROOT_TOKEN  "Vault 루트 토큰"
_require_var DOMAIN            "도메인 (예: mzclinic.cloud)"
_require_var ONPREM_PRIVATE_IP "온프레미스 사설 IP (예: 172.30.1.76)"
_require_var RDS_HOST          "RDS Aurora endpoint"
_require_var API_REPO_PATH     "deidentification-api 소스 경로"

log "=== 04-api.sh 시작 ==="

# ── 1. Vault에서 시크릿 읽기 ─────────────────────────────────────────────────
log "[1/6] Vault KV 시크릿 조회"

_vault_kv() {
    docker exec hospital_vault \
        sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
        vault kv get -field=$2 $1 2>/dev/null"
}

INTERNAL_API_TOKEN=$(_vault_kv "secret/hospital-auth" "internal_api_token") \
    || err "Vault에서 internal_api_token 읽기 실패 — 03.5-vault-bootstrap.sh 를 먼저 실행했나요?"
JWT_SECRET_KEY=$(_vault_kv "secret/hospital-auth" "jwt_secret_key") \
    || err "Vault에서 jwt_secret_key 읽기 실패"
JWT_SECRET_KEY_PREV=$(_vault_kv "secret/hospital-auth" "jwt_secret_key_previous" 2>/dev/null) \
    || { warn "jwt_secret_key_previous 없음 (무시)"; JWT_SECRET_KEY_PREV=""; }

# hospital-app AppRole secret_id 발급 (단기 사용 후 revoke 권장)
VAULT_ROLE_ID=$(docker exec hospital_vault \
    sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
    vault read -field=role_id auth/approle/role/hospital-app/role-id 2>/dev/null") \
    || err "hospital-app role_id 읽기 실패"

VAULT_SECRET_ID=$(docker exec hospital_vault \
    sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
    vault write -f -field=secret_id auth/approle/role/hospital-app/secret-id 2>/dev/null") \
    || err "hospital-app secret_id 발급 실패"

log "Vault 시크릿 로드 완료"

# ── 2. deidentification-api .env 작성 ────────────────────────────────────────
log "[2/6] deidentification-api .env 작성"

API_ENV_PATH="${API_REPO_PATH}/.env"

# 컨테이너 내부에서 Vault/DB 는 Docker 네트워크 hostname으로 접근
cat > "$API_ENV_PATH" <<EOF
# ============================================================
# deidentification-api 환경변수
# 생성: $(date '+%Y-%m-%d %H:%M:%S') by 04-api.sh
# 주의: git commit 금지
# ============================================================

# Vault — 컨테이너 내부에서 hospital-net hostname으로 접근
VAULT_ADDR=http://hospital_vault:8200
VAULT_ROLE_ID=${VAULT_ROLE_ID}
VAULT_SECRET_ID=${VAULT_SECRET_ID}

# 온프레미스 DB — 컨테이너 내부 hostname
ONPREM_HIS_DATABASE_URL=postgresql://hospital_db:5432/hospital

# RDS
RDS_HOST=${RDS_HOST}
RDS_PORT=5432
RDS_DB=hospital

# API 인증 (런타임에 Vault에서 다시 읽는 경우 제거 가능)
INTERNAL_API_TOKEN=${INTERNAL_API_TOKEN}
JWT_SECRET_KEY=${JWT_SECRET_KEY}
JWT_SECRET_KEY_PREVIOUS=${JWT_SECRET_KEY_PREV}

# 서비스
ONPREM_PRIVATE_IP=${ONPREM_PRIVATE_IP}
DOMAIN=${DOMAIN}
ENVIRONMENT=production

# CORS — AWS 프론트엔드에서 온프레미스 API 직접 호출 허용
ALLOWED_ORIGINS=https://staff.${DOMAIN}
EOF

chmod 600 "$API_ENV_PATH"
log ".env 작성 완료: $API_ENV_PATH"

# ── 3. SSL 인증서 준비 ────────────────────────────────────────────────────────
log "[3/6] SSL 인증서 준비"

SSL_DIR="/opt/hospital/nginx/ssl"
mkdir -p "$SSL_DIR"
CERT_FILE="${SSL_DIR}/fullchain.pem"
KEY_FILE="${SSL_DIR}/privkey.pem"

if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
    warn "기존 인증서 존재 — 스킵"
else
    warn "Self-signed 인증서 생성 (운영 전환 시 Let's Encrypt로 교체 필요)"
    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=${DOMAIN}/O=Hospital/C=KR" \
        -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN},IP:${ONPREM_PRIVATE_IP}"
    chmod 600 "$KEY_FILE"
    log "Self-signed 인증서 생성 완료"
fi

# ── 4. nginx 설정 작성 ───────────────────────────────────────────────────────
log "[4/6] nginx 설정 작성"

NGINX_CONF_DIR="/opt/hospital/nginx/conf.d"
NGINX_HTML_DIR="/opt/hospital/nginx/html"
mkdir -p "$NGINX_CONF_DIR" "$NGINX_HTML_DIR"

cat > "${NGINX_CONF_DIR}/hospital.conf" <<EOF
upstream deident_api {
    server deidentification-api:8000;
    keepalive 16;
}

server {
    listen 80;
    server_name ${DOMAIN} ${ONPREM_PRIVATE_IP};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN} ${ONPREM_PRIVATE_IP};

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    # HIS API
    location /api/ {
        proxy_pass         http://deident_api;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Connection "";
    }

    # 환자 포털
    location /portal/ {
        proxy_pass         http://deident_api;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Connection "";
    }

    # 관리자 — 내부망만 허용
    location /admin/ {
        proxy_pass         http://deident_api;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Connection "";
        allow 172.30.0.0/16;
        allow 10.0.0.0/16;
        deny  all;
    }

    # 정적 파일 (팀원 HTML 등)
    location / {
        root  /etc/nginx/html;
        index index.html;
        try_files \$uri \$uri/ =404;
    }

    location /health {
        access_log off;
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}
EOF

log "nginx 설정 작성 완료"

# ── 5. 이미지 빌드 ───────────────────────────────────────────────────────────
log "[5/6] deidentification-api 이미지 빌드"
[[ ! -f "${API_REPO_PATH}/Dockerfile" ]] && err "Dockerfile 없음: ${API_REPO_PATH}/Dockerfile"
cd "$API_REPO_PATH"
docker build -t deidentification-api:latest .
log "이미지 빌드 완료"

# ── 6. 검증 ──────────────────────────────────────────────────────────────────
log "[6/6] 준비 상태 검증"
echo "────────────────────────────────────────"
[[ -f "$API_ENV_PATH" ]]                     && echo -e "  ${GREEN}✔${NC} .env" || echo -e "  ${RED}✘${NC} .env"
[[ -f "$CERT_FILE" ]]                        && echo -e "  ${GREEN}✔${NC} SSL 인증서" || echo -e "  ${RED}✘${NC} SSL 인증서"
[[ -f "${NGINX_CONF_DIR}/hospital.conf" ]]   && echo -e "  ${GREEN}✔${NC} nginx 설정" || echo -e "  ${RED}✘${NC} nginx 설정"
docker image inspect deidentification-api:latest &>/dev/null \
    && echo -e "  ${GREEN}✔${NC} Docker 이미지" || echo -e "  ${RED}✘${NC} Docker 이미지"
echo "────────────────────────────────────────"

log "=== 04-api.sh 완료 ==="
warn "다음: 05-start.sh 실행"
