#!/usr/bin/env bash
# =============================================================================
# 06-post-setup.sh — Vault DB role 설정 + 스키마 적용 + 더미 데이터
# 순서:
#   1. Vault: database secrets engine 활성화 + DB config + roles
#   2. Vault: AppRole 설정 (hospital-app, hospital-db, lambda-role)
#   3. Vault: KV secrets engine + 정적 시크릿 저장
#   4. PostgreSQL: 스키마 적용 (member_number 등)
#   5. PostgreSQL: RLS 정책 적용
#   6. PostgreSQL: 더미 데이터 삽입 (환자 100, 의사 20, 간호사 10, 관리자 1)
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
}

_require_var VAULT_ROOT_TOKEN      "Vault 루트 토큰"
_require_var POSTGRES_PASSWORD     "PostgreSQL postgres 슈퍼유저 비밀번호"
_require_var POSTGRES_API_PASS     "PostgreSQL api_user 비밀번호"
_require_var RDS_HOST              "RDS Aurora endpoint"
_require_var RDS_PASSWORD          "RDS postgres 비밀번호"
_require_var INTERNAL_API_TOKEN    "내부 API 토큰"
_require_var JWT_SECRET_KEY        "JWT 시크릿 키"
_require_var JWT_SECRET_KEY_PREV   "JWT 이전 시크릿 키 (grace period)"

# Vault 실행 헬퍼
V() {
    docker exec hospital_vault \
        sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault $*"
}

# psql 실행 헬퍼 (onprem)
PG() {
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
        psql -U postgres -d hospital -c "$1"
}

log "=== 06-post-setup.sh 시작 ==="

# ══════════════════════════════════════════════════════════════════════════════
# 1. Vault: Secrets Engines
# ══════════════════════════════════════════════════════════════════════════════
log "[1/6] Vault Secrets Engines 활성화"

# database secrets engine
V "secrets enable -path=database database" 2>/dev/null \
    || warn "database secrets engine 이미 활성화됨"

# KV v2
V "secrets enable -path=secret kv-v2" 2>/dev/null \
    || warn "secret/ KV v2 이미 활성화됨"

# ── DB Config: onprem ─────────────────────────────────────────────────────────
log "Vault DB config: hospital-onprem"
V "write database/config/hospital-onprem \
    plugin_name=postgresql-database-plugin \
    allowed_roles='onprem-api-role' \
    connection_url='postgresql://{{username}}:{{password}}@hospital_db:5432/hospital?sslmode=disable' \
    username='postgres' \
    password='${POSTGRES_PASSWORD}'"

# ── DB Config: RDS ────────────────────────────────────────────────────────────
log "Vault DB config: rds-hospital"
V "write database/config/rds-hospital \
    plugin_name=postgresql-database-plugin \
    allowed_roles='api-role' \
    connection_url='postgresql://{{username}}:{{password}}@${RDS_HOST}:5432/hospital?sslmode=require' \
    username='postgres' \
    password='${RDS_PASSWORD}'"

# ── DB Role: onprem-api-role ──────────────────────────────────────────────────
log "Vault DB role: onprem-api-role"
V "write database/roles/onprem-api-role \
    db_name=hospital-onprem \
    default_ttl=1h \
    max_ttl=24h \
    creation_statements=\"
CREATE ROLE \\\"{{name}}\\\" LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO \\\"{{name}}\\\";
GRANT INSERT, UPDATE ON
    users, sessions, appointment_types, appointment_statuses,
    appointments, roles, menus, permissions, role_menus,
    role_permissions, password_policy, notification_types,
    notifications, login_history, appointment_history, user_mfa
    TO \\\"{{name}}\\\";
GRANT INSERT ON audit_logs TO \\\"{{name}}\\\";
ALTER ROLE \\\"{{name}}\\\" BYPASSRLS;
\""

# ── DB Role: api-role (RDS) ───────────────────────────────────────────────────
log "Vault DB role: api-role"
V "write database/roles/api-role \
    db_name=rds-hospital \
    default_ttl=1h \
    max_ttl=24h \
    creation_statements=\"
CREATE ROLE \\\"{{name}}\\\" LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \\\"{{name}}\\\";
\""

# ══════════════════════════════════════════════════════════════════════════════
# 2. Vault: Auth Methods + AppRole
# ══════════════════════════════════════════════════════════════════════════════
log "[2/6] Vault AppRole 설정"

V "auth enable approle" 2>/dev/null || warn "approle 이미 활성화됨"

# Policies
log "Vault policies 작성"

V "policy write hospital-auth -" <<'POLICY'
path "database/creds/rds-auth-role"   { capabilities = ["read"] }
path "database/creds/rds-portal-role" { capabilities = ["read"] }
path "database/creds/onprem-auth-role"{ capabilities = ["read"] }
path "auth/token/renew-self"          { capabilities = ["update"] }
POLICY

V "policy write hospital-db -" <<'POLICY'
path "secret/data/hospital/postgres" { capabilities = ["read"] }
path "secret/data/hospital/deident"  { capabilities = ["read"] }
path "database/creds/api-role"        { capabilities = ["read"] }
path "database/creds/onprem-api-role" { capabilities = ["read"] }
POLICY

V "policy write lambda-vault-policy -" <<'POLICY'
path "database/config/rds-hospital" { capabilities = ["create", "update", "read"] }
POLICY

# AppRoles
log "AppRole: hospital-app"
V "write auth/approle/role/hospital-app \
    token_policies='hospital-auth,hospital-db' \
    token_ttl=0 \
    token_max_ttl=0"

log "AppRole: hospital-db"
V "write auth/approle/role/hospital-db \
    token_policies='hospital-db' \
    token_ttl=1h \
    token_max_ttl=4h"

log "AppRole: lambda-role"
V "write auth/approle/role/lambda-role \
    token_policies='lambda-vault-policy' \
    token_ttl=5m \
    token_max_ttl=10m"

# ══════════════════════════════════════════════════════════════════════════════
# 3. Vault: KV 정적 시크릿
# ══════════════════════════════════════════════════════════════════════════════
log "[3/6] Vault KV 시크릿 저장"

V "kv put secret/hospital-auth \
    internal_api_token='${INTERNAL_API_TOKEN}' \
    jwt_secret_key='${JWT_SECRET_KEY}' \
    jwt_secret_key_previous='${JWT_SECRET_KEY_PREV}'"

V "kv put secret/hospital/postgres \
    username='postgres' \
    password='${POSTGRES_PASSWORD}'"

V "kv put secret/hospital/postgres-api \
    username='api_user' \
    password='${POSTGRES_API_PASS}'"

log "KV 시크릿 저장 완료"

# ══════════════════════════════════════════════════════════════════════════════
# 4. PostgreSQL 스키마 적용
# ══════════════════════════════════════════════════════════════════════════════
log "[4/6] PostgreSQL 스키마 적용"

PG "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# users 테이블: member_number, must_change_password 추가
PG "
DO \$\$
BEGIN
    -- member_number (로그인 아이디)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name='users' AND column_name='member_number'
    ) THEN
        ALTER TABLE users ADD COLUMN member_number VARCHAR(20) UNIQUE;
        RAISE NOTICE 'users.member_number 추가';
    END IF;

    -- must_change_password
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name='users' AND column_name='must_change_password'
    ) THEN
        ALTER TABLE users ADD COLUMN must_change_password BOOLEAN NOT NULL DEFAULT TRUE;
        RAISE NOTICE 'users.must_change_password 추가';
    END IF;

    -- email nullable
    ALTER TABLE users ALTER COLUMN email DROP NOT NULL;
END
\$\$;
"

# patients 테이블: member_number(8자리), internal_seq 추가
PG "
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name='patients' AND column_name='member_number'
    ) THEN
        ALTER TABLE patients ADD COLUMN member_number CHAR(8) UNIQUE;
        RAISE NOTICE 'patients.member_number 추가';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name='patients' AND column_name='internal_seq'
    ) THEN
        CREATE SEQUENCE IF NOT EXISTS patients_internal_seq_seq;
        ALTER TABLE patients ADD COLUMN internal_seq BIGINT
            DEFAULT nextval('patients_internal_seq_seq');
        RAISE NOTICE 'patients.internal_seq 추가';
    END IF;
END
\$\$;
"

# encounters 테이블: encounter_type nullable
PG "
DO \$\$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name='encounters' AND column_name='encounter_type'
        AND is_nullable='NO'
    ) THEN
        ALTER TABLE encounters ALTER COLUMN encounter_type DROP NOT NULL;
        RAISE NOTICE 'encounters.encounter_type → nullable';
    END IF;
END
\$\$;
"

# pending_patients 삭제
PG "DROP TABLE IF EXISTS pending_patients CASCADE;"
log "pending_patients 테이블 삭제 (이미 없으면 무시)"

log "스키마 적용 완료"

# ══════════════════════════════════════════════════════════════════════════════
# 5. RLS 정책 적용
# ══════════════════════════════════════════════════════════════════════════════
log "[5/6] RLS 정책 적용"

# RLS 활성화
for tbl in patients encounters diagnoses clinical_notes allergies surgery_histories; do
    PG "ALTER TABLE ${tbl} ENABLE ROW LEVEL SECURITY;" 2>/dev/null || true
done

# ── patients ──────────────────────────────────────────────────────────────────
PG "
DROP POLICY IF EXISTS patients_admin  ON patients;
DROP POLICY IF EXISTS patients_nurse  ON patients;
DROP POLICY IF EXISTS patients_doctor ON patients;
DROP POLICY IF EXISTS patients_self   ON patients;

CREATE POLICY patients_admin  ON patients FOR ALL TO role_admin  USING (true);
CREATE POLICY patients_nurse  ON patients FOR ALL TO role_nurse  USING (true);
CREATE POLICY patients_doctor ON patients FOR ALL TO role_doctor
    USING (id IN (SELECT patient_id FROM encounters WHERE doctor_id = current_setting('app.user_id')::BIGINT));
CREATE POLICY patients_self   ON patients FOR SELECT TO role_patient
    USING (member_number = current_setting('app.member_number'));
"

# ── encounters ────────────────────────────────────────────────────────────────
PG "
DROP POLICY IF EXISTS encounters_admin  ON encounters;
DROP POLICY IF EXISTS encounters_nurse  ON encounters;
DROP POLICY IF EXISTS encounters_doctor ON encounters;
DROP POLICY IF EXISTS encounters_self   ON encounters;

CREATE POLICY encounters_admin  ON encounters FOR ALL TO role_admin USING (true);
CREATE POLICY encounters_nurse  ON encounters FOR ALL TO role_nurse USING (true);
CREATE POLICY encounters_doctor ON encounters FOR ALL TO role_doctor
    USING (doctor_id = current_setting('app.user_id')::BIGINT);
CREATE POLICY encounters_self   ON encounters FOR SELECT TO role_patient
    USING (patient_id IN (
        SELECT id FROM patients WHERE member_number = current_setting('app.member_number')
    ));
"

# ── diagnoses, clinical_notes ─────────────────────────────────────────────────
for tbl in diagnoses clinical_notes; do
PG "
DROP POLICY IF EXISTS ${tbl}_admin  ON ${tbl};
DROP POLICY IF EXISTS ${tbl}_doctor ON ${tbl};
DROP POLICY IF EXISTS ${tbl}_self   ON ${tbl};

CREATE POLICY ${tbl}_admin  ON ${tbl} FOR ALL TO role_admin USING (true);
CREATE POLICY ${tbl}_doctor ON ${tbl} FOR ALL TO role_doctor
    USING (encounter_id IN (
        SELECT id FROM encounters WHERE doctor_id = current_setting('app.user_id')::BIGINT
    ));
CREATE POLICY ${tbl}_self   ON ${tbl} FOR SELECT TO role_patient
    USING (encounter_id IN (
        SELECT e.id FROM encounters e
        JOIN patients p ON e.patient_id = p.id
        WHERE p.member_number = current_setting('app.member_number')
    ));
"
done

# ── allergies ─────────────────────────────────────────────────────────────────
PG "
DROP POLICY IF EXISTS allergies_admin  ON allergies;
DROP POLICY IF EXISTS allergies_nurse  ON allergies;
DROP POLICY IF EXISTS allergies_doctor ON allergies;
DROP POLICY IF EXISTS allergies_self   ON allergies;

CREATE POLICY allergies_admin  ON allergies FOR ALL TO role_admin USING (true);
CREATE POLICY allergies_nurse  ON allergies FOR ALL TO role_nurse USING (true);
CREATE POLICY allergies_doctor ON allergies FOR ALL TO role_doctor
    USING (patient_id IN (
        SELECT patient_id FROM encounters WHERE doctor_id = current_setting('app.user_id')::BIGINT
    ));
CREATE POLICY allergies_self   ON allergies FOR SELECT TO role_patient
    USING (patient_id IN (
        SELECT id FROM patients WHERE member_number = current_setting('app.member_number')
    ));
"

# ── surgery_histories ─────────────────────────────────────────────────────────
PG "
DROP POLICY IF EXISTS surgery_histories_admin  ON surgery_histories;
DROP POLICY IF EXISTS surgery_histories_doctor ON surgery_histories;
DROP POLICY IF EXISTS surgery_histories_self   ON surgery_histories;

CREATE POLICY surgery_histories_admin  ON surgery_histories FOR ALL TO role_admin USING (true);
CREATE POLICY surgery_histories_doctor ON surgery_histories FOR ALL TO role_doctor
    USING (patient_id IN (
        SELECT patient_id FROM encounters WHERE doctor_id = current_setting('app.user_id')::BIGINT
    ));
CREATE POLICY surgery_histories_self   ON surgery_histories FOR SELECT TO role_patient
    USING (patient_id IN (
        SELECT id FROM patients WHERE member_number = current_setting('app.member_number')
    ));
"

log "RLS 정책 적용 완료"

# ══════════════════════════════════════════════════════════════════════════════
# 6. 더미 데이터
# ══════════════════════════════════════════════════════════════════════════════
log "[6/6] 더미 데이터 삽입"

# 기본 역할 삽입
PG "
INSERT INTO roles (name, description) VALUES
    ('role_admin',   '관리자'),
    ('role_doctor',  '의사'),
    ('role_nurse',   '간호사'),
    ('role_patient', '환자')
ON CONFLICT (name) DO NOTHING;
"

# 관리자 1명
PG "
INSERT INTO users (username, member_number, password_hash, must_change_password, email)
VALUES ('admin-1', 'admin-1',
    crypt('Test1234!', gen_salt('bf')), false, NULL)
ON CONFLICT (member_number) DO NOTHING;
"

# 의사 20명 (dr-내과-001 ~ dr-내과-020)
PG "
DO \$\$
DECLARE i INT;
BEGIN
    FOR i IN 1..20 LOOP
        INSERT INTO users (username, member_number, password_hash, must_change_password, email)
        VALUES (
            format('dr-내과-%03s', i),
            format('dr-내과-%03s', i),
            crypt('Test1234!', gen_salt('bf')),
            true,
            NULL
        ) ON CONFLICT (member_number) DO NOTHING;
    END LOOP;
END
\$\$;
"

# 간호사 10명
PG "
DO \$\$
DECLARE i INT;
BEGIN
    FOR i IN 1..10 LOOP
        INSERT INTO users (username, member_number, password_hash, must_change_password, email)
        VALUES (
            format('nurse-%03s', i),
            format('nurse-%03s', i),
            crypt('Test1234!', gen_salt('bf')),
            true,
            NULL
        ) ON CONFLICT (member_number) DO NOTHING;
    END LOOP;
END
\$\$;
"

# 환자 100명 (8자리 랜덤 숫자 member_number, 초기 비밀번호 = 생년월일)
PG "
DO \$\$
DECLARE
    i        INT;
    mn       CHAR(8);
    bdate    DATE;
    bdate_pw TEXT;
BEGIN
    FOR i IN 1..100 LOOP
        -- 8자리 랜덤 숫자 member_number
        mn := lpad((floor(random() * 90000000) + 10000000)::TEXT, 8, '0');

        -- 1960~2005 사이 랜덤 생년월일
        bdate := ('1960-01-01'::DATE + (floor(random() * 16436))::INT);
        bdate_pw := to_char(bdate, 'YYYYMMDD');

        -- patients 테이블
        INSERT INTO patients (
            name, birth_date, gender_code, member_number
        ) VALUES (
            format('환자%s', i),
            bdate,
            CASE WHEN random() > 0.5 THEN 'M' ELSE 'F' END,
            mn
        ) ON CONFLICT (member_number) DO NOTHING;

        -- users 테이블 (환자 로그인 계정)
        INSERT INTO users (username, member_number, password_hash, must_change_password, email)
        VALUES (
            mn,
            mn,
            crypt(bdate_pw, gen_salt('bf')),
            true,
            NULL
        ) ON CONFLICT (member_number) DO NOTHING;
    END LOOP;
END
\$\$;
"

log "더미 데이터 삽입 완료"

# ── 최종 카운트 확인 ──────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
PG "SELECT
    (SELECT count(*) FROM users  WHERE member_number LIKE 'admin%') AS 관리자,
    (SELECT count(*) FROM users  WHERE member_number LIKE 'dr-%')   AS 의사,
    (SELECT count(*) FROM users  WHERE member_number LIKE 'nurse%') AS 간호사,
    (SELECT count(*) FROM patients)                                  AS 환자;"
echo "════════════════════════════════════════"

log "=== 06-post-setup.sh 완료 ==="
warn "전체 IaC 설치 완료! 서비스 상태: docker ps"
