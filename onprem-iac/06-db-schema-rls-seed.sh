#!/usr/bin/env bash
# =============================================================================
# 06-db-schema-rls-seed.sh — DB 스키마 + role 권한 + RLS + 더미 데이터 + Vault DB roles
# 실행 순서: 03.5 완료 후 → 04-api.sh / 05-start.sh 이전 (API 기동 전 dynamic role 필수)
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
    [[ "${!var}" =~ ^__.*__$ ]] && err "$var 가 placeholder 그대로입니다."
}

_require_var VAULT_ROOT_TOKEN  "Vault 루트 토큰"
_require_var POSTGRES_PASSWORD "PostgreSQL postgres 비밀번호"
_require_var RDS_HOST          "RDS Aurora endpoint"
_require_var RDS_PASSWORD      "RDS postgres 비밀번호"

V() {
    docker exec hospital_vault \
        sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault $*"
}
PG_FILE() {
    docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
        psql -U postgres -d hospital
}

log "=== 06-db-schema-rls-seed.sh 시작 ==="

# ── 사전 체크: appointment_types / statuses 중복 데이터 확인 ──────────────────
# 구버전 스크립트로 이미 중복 데이터가 들어간 경우 CREATE UNIQUE INDEX 에서 실패함
# 새 DB라면 당연히 0건이므로 그냥 통과
log "[0/6] 사전 체크: appointment 중복 데이터 확인"

TYPES_DUP=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
    psql -U postgres -d hospital -tAc \
    "SELECT count(*) FROM (
        SELECT name FROM appointment_types GROUP BY name HAVING count(*) > 1
     ) t;" 2>/dev/null || echo "0")

STATUS_DUP=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
    psql -U postgres -d hospital -tAc \
    "SELECT count(*) FROM (
        SELECT name FROM appointment_statuses GROUP BY name HAVING count(*) > 1
     ) t;" 2>/dev/null || echo "0")

# 테이블이 아직 없으면 psql이 에러를 내고 위 결과가 비어있을 수 있음 → 0으로 처리
TYPES_DUP="${TYPES_DUP:-0}"
STATUS_DUP="${STATUS_DUP:-0}"

if [[ "$TYPES_DUP" -gt 0 || "$STATUS_DUP" -gt 0 ]]; then
    err "중복 데이터 발견 — CREATE UNIQUE INDEX 실패 방지를 위해 수동 정리 후 재실행하세요.
  appointment_types 중복: ${TYPES_DUP}건
  appointment_statuses 중복: ${STATUS_DUP}건

  확인 쿼리:
    SELECT name, count(*) FROM appointment_types GROUP BY name HAVING count(*) > 1;
    SELECT name, count(*) FROM appointment_statuses GROUP BY name HAVING count(*) > 1;

  정리 예시 (중복 중 id가 큰 행 삭제):
    DELETE FROM appointment_types WHERE id NOT IN (
        SELECT MIN(id) FROM appointment_types GROUP BY name);
    DELETE FROM appointment_statuses WHERE id NOT IN (
        SELECT MIN(id) FROM appointment_statuses GROUP BY name);"
fi
log "사전 체크 완료 (중복 없음) ✔"

# ══════════════════════════════════════════════════════════════════════════════
# 1. Base 스키마
# ══════════════════════════════════════════════════════════════════════════════
log "[1/6] Base 스키마 적용"

PG_FILE << 'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS roles (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(50) UNIQUE NOT NULL,
    description TEXT
);
CREATE TABLE IF NOT EXISTS menus (
    id        SERIAL PRIMARY KEY,
    name      VARCHAR(100) NOT NULL,
    path      VARCHAR(200),
    parent_id INT REFERENCES menus(id)
);
CREATE TABLE IF NOT EXISTS permissions (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) UNIQUE NOT NULL,
    description TEXT
);
CREATE TABLE IF NOT EXISTS role_menus (
    role_id INT REFERENCES roles(id) ON DELETE CASCADE,
    menu_id INT REFERENCES menus(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, menu_id)
);
CREATE TABLE IF NOT EXISTS role_permissions (
    role_id       INT REFERENCES roles(id) ON DELETE CASCADE,
    permission_id INT REFERENCES permissions(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);
CREATE TABLE IF NOT EXISTS password_policy (
    id              SERIAL PRIMARY KEY,
    min_length      INT  NOT NULL DEFAULT 8,
    require_upper   BOOL NOT NULL DEFAULT TRUE,
    require_digit   BOOL NOT NULL DEFAULT TRUE,
    require_special BOOL NOT NULL DEFAULT TRUE,
    max_age_days    INT  NOT NULL DEFAULT 90,
    history_count   INT  NOT NULL DEFAULT 5
);
INSERT INTO password_policy (id) VALUES (1) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS users (
    id                   BIGSERIAL    PRIMARY KEY,
    username             VARCHAR(100) NOT NULL,
    member_number        VARCHAR(20)  UNIQUE NOT NULL,
    password_hash        TEXT         NOT NULL,
    email                TEXT,
    must_change_password BOOLEAN      NOT NULL DEFAULT TRUE,
    is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS user_mfa (
    id         BIGSERIAL   PRIMARY KEY,
    user_id    BIGINT      REFERENCES users(id) ON DELETE CASCADE,
    mfa_type   VARCHAR(20) NOT NULL,
    secret     TEXT        NOT NULL,
    is_enabled BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS sessions (
    id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id    BIGINT      REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    ip_address INET
);
CREATE TABLE IF NOT EXISTS login_history (
    id         BIGSERIAL   PRIMARY KEY,
    user_id    BIGINT      REFERENCES users(id) ON DELETE SET NULL,
    login_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ip_address INET,
    success    BOOLEAN     NOT NULL
);

CREATE SEQUENCE IF NOT EXISTS patients_internal_seq_seq;
CREATE TABLE IF NOT EXISTS patients (
    id            BIGSERIAL   PRIMARY KEY,
    member_number CHAR(8)     UNIQUE NOT NULL,
    internal_seq  BIGINT      NOT NULL DEFAULT nextval('patients_internal_seq_seq'),
    name          VARCHAR(100),
    birth_date    DATE,
    gender_code   CHAR(1),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS encounters (
    id             BIGSERIAL   PRIMARY KEY,
    patient_id     BIGINT      REFERENCES patients(id) ON DELETE CASCADE,
    doctor_id      BIGINT      REFERENCES users(id),
    visit_date     DATE,
    encounter_type VARCHAR(50),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS diagnoses (
    id             BIGSERIAL   PRIMARY KEY,
    encounter_id   BIGINT      REFERENCES encounters(id) ON DELETE CASCADE,
    diagnosis_code VARCHAR(20),
    description    TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS clinical_notes (
    id           BIGSERIAL   PRIMARY KEY,
    encounter_id BIGINT      REFERENCES encounters(id) ON DELETE CASCADE,
    note         TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS allergies (
    id         BIGSERIAL   PRIMARY KEY,
    patient_id BIGINT      REFERENCES patients(id) ON DELETE CASCADE,
    allergen   VARCHAR(200),
    severity   VARCHAR(50),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS surgery_histories (
    id           BIGSERIAL   PRIMARY KEY,
    patient_id   BIGINT      REFERENCES patients(id) ON DELETE CASCADE,
    surgery_name VARCHAR(200),
    surgery_date DATE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- UNIQUE: 재실행 시 ON CONFLICT (name) 동작 보장
CREATE TABLE IF NOT EXISTS appointment_types (
    id   SERIAL       PRIMARY KEY,
    name VARCHAR(100) UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS appointment_statuses (
    id   SERIAL      PRIMARY KEY,
    name VARCHAR(50) UNIQUE NOT NULL
);
-- 기존 테이블에 UNIQUE가 없을 경우 대비 (IF NOT EXISTS로 안전하게 추가)
CREATE UNIQUE INDEX IF NOT EXISTS idx_appointment_types_name   ON appointment_types(name);
CREATE UNIQUE INDEX IF NOT EXISTS idx_appointment_statuses_name ON appointment_statuses(name);

CREATE TABLE IF NOT EXISTS appointments (
    id           BIGSERIAL   PRIMARY KEY,
    patient_id   BIGINT      REFERENCES patients(id),
    doctor_id    BIGINT      REFERENCES users(id),
    type_id      INT         REFERENCES appointment_types(id),
    status_id    INT         REFERENCES appointment_statuses(id),
    scheduled_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS appointment_history (
    id             BIGSERIAL   PRIMARY KEY,
    appointment_id BIGINT      REFERENCES appointments(id) ON DELETE CASCADE,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    old_status_id  INT,
    new_status_id  INT,
    changed_by     BIGINT      REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS notification_types (
    id   SERIAL       PRIMARY KEY,
    name VARCHAR(100) NOT NULL
);
CREATE TABLE IF NOT EXISTS notifications (
    id         BIGSERIAL   PRIMARY KEY,
    user_id    BIGINT      REFERENCES users(id) ON DELETE CASCADE,
    type_id    INT         REFERENCES notification_types(id),
    message    TEXT,
    is_read    BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS audit_logs (
    id         BIGSERIAL   PRIMARY KEY,
    user_id    BIGINT,
    action     VARCHAR(100),
    table_name VARCHAR(100),
    record_id  BIGINT,
    detail     JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SQL

log "Base 스키마 완료"

# ══════════════════════════════════════════════════════════════════════════════
# 2. role_* 테이블/시퀀스 권한 부여
# SET LOCAL ROLE role_doctor 시 권한 검사는 role_doctor 기준으로 적용됨
# dynamic role 자체의 GRANT가 아니라 여기서 role_* 에 직접 부여해야 함
# ══════════════════════════════════════════════════════════════════════════════
log "[2/6] role_* 테이블/시퀀스 권한 부여"

PG_FILE << 'SQL'
-- 시퀀스 권한 (BIGSERIAL 사용 테이블의 nextval 호출에 필요)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public
    TO role_admin, role_doctor, role_nurse, role_patient;

-- role_admin: 전체 관리
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO role_admin;

-- role_doctor: 담당 환자 임상 정보 조회 + 진료 기록 작성
GRANT SELECT ON
    patients, encounters, diagnoses, clinical_notes,
    allergies, surgery_histories, appointments,
    appointment_types, appointment_statuses
    TO role_doctor;
GRANT INSERT, UPDATE ON
    encounters, diagnoses, clinical_notes, audit_logs
    TO role_doctor;

-- role_nurse: 환자/알레르기 조회 + 예약/알림 관리
GRANT SELECT ON
    patients, encounters, allergies,
    appointments, appointment_types, appointment_statuses
    TO role_nurse;
GRANT INSERT, UPDATE ON
    appointments, appointment_history,
    notifications, login_history, audit_logs
    TO role_nurse;

-- role_patient: 본인 정보 조회 전용
GRANT SELECT ON
    patients, encounters, diagnoses, clinical_notes,
    allergies, surgery_histories, appointments,
    appointment_types, appointment_statuses
    TO role_patient;
GRANT INSERT ON login_history, audit_logs TO role_patient;
SQL

log "role_* 권한 부여 완료"

# ══════════════════════════════════════════════════════════════════════════════
# 3. RLS 정책
# current_setting(..., true)  → missing_ok, 값 없으면 NULL
# NULLIF(..., '')::BIGINT      → 빈 문자열 캐스팅 에러 방지
# ══════════════════════════════════════════════════════════════════════════════
log "[3/6] RLS 정책 적용"

PG_FILE << 'SQL'
ALTER TABLE patients          ENABLE ROW LEVEL SECURITY;
ALTER TABLE encounters        ENABLE ROW LEVEL SECURITY;
ALTER TABLE diagnoses         ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical_notes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE allergies         ENABLE ROW LEVEL SECURITY;
ALTER TABLE surgery_histories ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointments      ENABLE ROW LEVEL SECURITY;

-- ── patients ──────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS patients_admin  ON patients;
DROP POLICY IF EXISTS patients_nurse  ON patients;
DROP POLICY IF EXISTS patients_doctor ON patients;
DROP POLICY IF EXISTS patients_self   ON patients;

CREATE POLICY patients_admin  ON patients FOR ALL TO role_admin USING (true);
CREATE POLICY patients_nurse  ON patients FOR ALL TO role_nurse USING (true);
CREATE POLICY patients_doctor ON patients FOR ALL TO role_doctor
    USING (id IN (
        SELECT patient_id FROM encounters
        WHERE doctor_id = NULLIF(current_setting('app.user_id', true), '')::BIGINT
    ));
CREATE POLICY patients_self ON patients FOR SELECT TO role_patient
    USING (member_number = current_setting('app.member_number', true));

-- ── encounters ────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS encounters_admin  ON encounters;
DROP POLICY IF EXISTS encounters_nurse  ON encounters;
DROP POLICY IF EXISTS encounters_doctor ON encounters;
DROP POLICY IF EXISTS encounters_self   ON encounters;

CREATE POLICY encounters_admin  ON encounters FOR ALL TO role_admin USING (true);
CREATE POLICY encounters_nurse  ON encounters FOR ALL TO role_nurse USING (true);
CREATE POLICY encounters_doctor ON encounters FOR ALL TO role_doctor
    USING (doctor_id = NULLIF(current_setting('app.user_id', true), '')::BIGINT);
CREATE POLICY encounters_self   ON encounters FOR SELECT TO role_patient
    USING (patient_id IN (
        SELECT id FROM patients
        WHERE member_number = current_setting('app.member_number', true)
    ));

-- ── diagnoses ─────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS diagnoses_admin  ON diagnoses;
DROP POLICY IF EXISTS diagnoses_doctor ON diagnoses;
DROP POLICY IF EXISTS diagnoses_self   ON diagnoses;

CREATE POLICY diagnoses_admin  ON diagnoses FOR ALL TO role_admin USING (true);
CREATE POLICY diagnoses_doctor ON diagnoses FOR ALL TO role_doctor
    USING (encounter_id IN (
        SELECT id FROM encounters
        WHERE doctor_id = NULLIF(current_setting('app.user_id', true), '')::BIGINT
    ));
CREATE POLICY diagnoses_self   ON diagnoses FOR SELECT TO role_patient
    USING (encounter_id IN (
        SELECT e.id FROM encounters e
        JOIN patients p ON e.patient_id = p.id
        WHERE p.member_number = current_setting('app.member_number', true)
    ));

-- ── clinical_notes ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS clinical_notes_admin  ON clinical_notes;
DROP POLICY IF EXISTS clinical_notes_doctor ON clinical_notes;
DROP POLICY IF EXISTS clinical_notes_self   ON clinical_notes;

CREATE POLICY clinical_notes_admin  ON clinical_notes FOR ALL TO role_admin USING (true);
CREATE POLICY clinical_notes_doctor ON clinical_notes FOR ALL TO role_doctor
    USING (encounter_id IN (
        SELECT id FROM encounters
        WHERE doctor_id = NULLIF(current_setting('app.user_id', true), '')::BIGINT
    ));
CREATE POLICY clinical_notes_self   ON clinical_notes FOR SELECT TO role_patient
    USING (encounter_id IN (
        SELECT e.id FROM encounters e
        JOIN patients p ON e.patient_id = p.id
        WHERE p.member_number = current_setting('app.member_number', true)
    ));

-- ── allergies ─────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS allergies_admin  ON allergies;
DROP POLICY IF EXISTS allergies_nurse  ON allergies;
DROP POLICY IF EXISTS allergies_doctor ON allergies;
DROP POLICY IF EXISTS allergies_self   ON allergies;

CREATE POLICY allergies_admin  ON allergies FOR ALL TO role_admin USING (true);
CREATE POLICY allergies_nurse  ON allergies FOR ALL TO role_nurse USING (true);
CREATE POLICY allergies_doctor ON allergies FOR ALL TO role_doctor
    USING (patient_id IN (
        SELECT patient_id FROM encounters
        WHERE doctor_id = NULLIF(current_setting('app.user_id', true), '')::BIGINT
    ));
CREATE POLICY allergies_self   ON allergies FOR SELECT TO role_patient
    USING (patient_id IN (
        SELECT id FROM patients
        WHERE member_number = current_setting('app.member_number', true)
    ));

-- ── surgery_histories ─────────────────────────────────────────────────────────
DROP POLICY IF EXISTS surgery_histories_admin  ON surgery_histories;
DROP POLICY IF EXISTS surgery_histories_doctor ON surgery_histories;
DROP POLICY IF EXISTS surgery_histories_self   ON surgery_histories;

CREATE POLICY surgery_histories_admin  ON surgery_histories FOR ALL TO role_admin USING (true);
CREATE POLICY surgery_histories_doctor ON surgery_histories FOR ALL TO role_doctor
    USING (patient_id IN (
        SELECT patient_id FROM encounters
        WHERE doctor_id = NULLIF(current_setting('app.user_id', true), '')::BIGINT
    ));
CREATE POLICY surgery_histories_self   ON surgery_histories FOR SELECT TO role_patient
    USING (patient_id IN (
        SELECT id FROM patients
        WHERE member_number = current_setting('app.member_number', true)
    ));

-- ── appointments ─────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS appointments_admin   ON appointments;
DROP POLICY IF EXISTS appointments_nurse   ON appointments;
DROP POLICY IF EXISTS appointments_doctor  ON appointments;
DROP POLICY IF EXISTS appointments_patient ON appointments;

CREATE POLICY appointments_admin ON appointments
    FOR ALL TO role_admin USING (true);

-- 간호사: 예약 전체 관리 (접수/변경/취소 업무상 필요)
CREATE POLICY appointments_nurse ON appointments
    FOR ALL TO role_nurse USING (true);

CREATE POLICY appointments_doctor ON appointments
    FOR SELECT TO role_doctor
    USING (doctor_id = NULLIF(current_setting('app.user_id', true), '')::BIGINT);

CREATE POLICY appointments_patient ON appointments
    FOR SELECT TO role_patient
    USING (patient_id IN (
        SELECT id FROM patients
        WHERE member_number = current_setting('app.member_number', true)
    ));
SQL

log "RLS 정책 완료"

# ══════════════════════════════════════════════════════════════════════════════
# 4. 더미 데이터
# ══════════════════════════════════════════════════════════════════════════════
log "[4/6] 더미 데이터 삽입"

PG_FILE << 'SQL'
INSERT INTO roles (name, description) VALUES
    ('role_admin',   '관리자'),
    ('role_doctor',  '의사'),
    ('role_nurse',   '간호사'),
    ('role_patient', '환자')
ON CONFLICT (name) DO NOTHING;

INSERT INTO appointment_types   (name) VALUES ('초진'),('재진'),('검사')          ON CONFLICT (name) DO NOTHING;
INSERT INTO appointment_statuses(name) VALUES ('대기'),('확정'),('완료'),('취소') ON CONFLICT (name) DO NOTHING;
SQL

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
    psql -U postgres -d hospital -c "
INSERT INTO users (username, member_number, password_hash, must_change_password)
VALUES ('admin-1','admin-1', crypt('Test1234!', gen_salt('bf')), TRUE)
ON CONFLICT (member_number) DO NOTHING;"

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
    psql -U postgres -d hospital -c "
DO \$\$
DECLARE i INT;
BEGIN
    FOR i IN 1..20 LOOP
        INSERT INTO users (username, member_number, password_hash, must_change_password)
        VALUES (format('dr-내과-%03s',i), format('dr-내과-%03s',i),
                crypt('Test1234!', gen_salt('bf')), TRUE)
        ON CONFLICT (member_number) DO NOTHING;
    END LOOP;
END \$\$;"

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
    psql -U postgres -d hospital -c "
DO \$\$
DECLARE i INT;
BEGIN
    FOR i IN 1..10 LOOP
        INSERT INTO users (username, member_number, password_hash, must_change_password)
        VALUES (format('nurse-%03s',i), format('nurse-%03s',i),
                crypt('Test1234!', gen_salt('bf')), TRUE)
        ON CONFLICT (member_number) DO NOTHING;
    END LOOP;
END \$\$;"

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
    psql -U postgres -d hospital -c "
DO \$\$
DECLARE
    i       INT;
    mn      CHAR(8);
    bdate   DATE;
    init_pw TEXT;
BEGIN
    FOR i IN 1..100 LOOP
        mn      := lpad((floor(random()*90000000)+10000000)::BIGINT::TEXT, 8, '0');
        bdate   := '1960-01-01'::DATE + (floor(random()*16436))::INT;
        init_pw := encode(gen_random_bytes(9), 'base64');
        INSERT INTO patients (member_number, name, birth_date, gender_code)
        VALUES (mn, format('환자%s',i), bdate,
                CASE WHEN random()>0.5 THEN 'M' ELSE 'F' END)
        ON CONFLICT (member_number) DO NOTHING;
        INSERT INTO users (username, member_number, password_hash, must_change_password)
        VALUES (mn, mn, crypt(init_pw, gen_salt('bf')), TRUE)
        ON CONFLICT (member_number) DO NOTHING;
    END LOOP;
END \$\$;"

log "더미 데이터 완료"

# ══════════════════════════════════════════════════════════════════════════════
# 5. Vault DB secrets engine + dynamic credential roles
# INHERIT FALSE: role 전환 권한만 부여, 권한 자동 상속 차단
# → dynamic role은 직접 RLS 정책이 없음
# → 앱이 BEGIN; SET LOCAL ROLE role_xxx; ... COMMIT; 으로 명시 전환해야 함
# ══════════════════════════════════════════════════════════════════════════════
log "[5/6] Vault DB secrets engine + roles 설정"

V "secrets enable -path=database database" 2>/dev/null \
    || warn "database secrets engine 이미 활성화됨"

V "write database/config/hospital-onprem \
    plugin_name=postgresql-database-plugin \
    allowed_roles='onprem-api-role' \
    connection_url='postgresql://{{username}}:{{password}}@hospital_db:5432/hospital?sslmode=disable' \
    username='postgres' \
    password='${POSTGRES_PASSWORD}'"

V "write database/config/rds-hospital \
    plugin_name=postgresql-database-plugin \
    allowed_roles='api-role' \
    connection_url='postgresql://{{username}}:{{password}}@${RDS_HOST}:5432/hospital?sslmode=require' \
    username='postgres' \
    password='${RDS_PASSWORD}'"

# onprem-api-role:
#   - IN ROLE api_user: 기본 테이블 권한 상속용 (api_user에 테이블 권한은 없음)
#   - GRANT role_* WITH INHERIT FALSE: SET LOCAL ROLE 전환 허용, 자동 상속 차단
#   → dynamic role은 SET LOCAL ROLE 없이 쿼리하면 RLS policy가 없어 빈 결과 반환
V "write database/roles/onprem-api-role \
    db_name=hospital-onprem \
    default_ttl=1h \
    max_ttl=24h \
    creation_statements=\"
CREATE ROLE \\\"{{name}}\\\" LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE api_user;
GRANT role_admin   TO \\\"{{name}}\\\" WITH INHERIT FALSE, SET TRUE;
GRANT role_doctor  TO \\\"{{name}}\\\" WITH INHERIT FALSE, SET TRUE;
GRANT role_nurse   TO \\\"{{name}}\\\" WITH INHERIT FALSE, SET TRUE;
GRANT role_patient TO \\\"{{name}}\\\" WITH INHERIT FALSE, SET TRUE;
GRANT INSERT ON audit_logs TO \\\"{{name}}\\\";
\""

V "write database/roles/api-role \
    db_name=rds-hospital \
    default_ttl=1h \
    max_ttl=24h \
    creation_statements=\"
CREATE ROLE \\\"{{name}}\\\" LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \\\"{{name}}\\\";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \\\"{{name}}\\\";
\""

log "Vault DB roles 완료"

# ══════════════════════════════════════════════════════════════════════════════
# 6. 최종 검증
# ══════════════════════════════════════════════════════════════════════════════
log "[6/6] 최종 검증"
echo ""
echo "════════════════════════════════════════"

log "사용자 현황:"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
    psql -U postgres -d hospital -c "
SELECT
    (SELECT count(*) FROM users   WHERE member_number LIKE 'admin%') AS 관리자,
    (SELECT count(*) FROM users   WHERE member_number LIKE 'dr-%')   AS 의사,
    (SELECT count(*) FROM users   WHERE member_number LIKE 'nurse%') AS 간호사,
    (SELECT count(*) FROM patients)                                   AS 환자;"

log "RLS 활성화 테이블:"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" hospital_db \
    psql -U postgres -d hospital -c "
SELECT tablename FROM pg_tables
WHERE schemaname='public' AND rowsecurity=true ORDER BY tablename;"

log "Vault DB roles:"
V "list database/roles" 2>/dev/null || warn "조회 실패"

echo "════════════════════════════════════════"
log "=== 06-db-schema-rls-seed.sh 완료 ==="
warn "다음: 04-api.sh → 05-start.sh"
warn "API 구현 참고: 모든 DB 쿼리는 트랜잭션 내에서 SET LOCAL ROLE + SET LOCAL app.* 세팅 필요"
warn "  BEGIN;"
warn "  SET LOCAL ROLE role_doctor;"
warn "  SET LOCAL app.user_id = '<user_id>';"
warn "  -- query"
warn "  COMMIT;"
