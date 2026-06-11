-- =============================================================
-- AWS RDS Aurora PostgreSQL 17.x — 전체 스키마 초기화
-- 대상: hospital-rds 클러스터 (ap-south-2)
-- 실행: psql -h <RDS_ENDPOINT> -U hospital_user -d hospital -f rds_init.sql
--
-- 갱신: 2026-06-11 — 라이브 DB(aws-aurora-01) pg_dump 기준으로 동기화
--   · sync_* 테이블 patient_hash → patient_id_hash(SALTED) 통일 + FK 추가
--   · users: member_number / display_name / must_change_password /
--            password_expires_at / synced_at 추가, email NULL 허용
--   · 신규 테이블: sync_logs, cloudsql_audit_logs
--   · 신규 함수/트리거: update_password_expires_at (+90일)
--   · DB 사용자: api_user 폐기 → ecs_patient_user / ecs_staff_user /
--               keycloak / pglogical_repl / dump_user
--
-- 데이터 민감도 원칙
--   1등급: AWS 저장 불가 (성명, 주민번호, 진단 원문 등)
--   2등급: 비식별화 후 조건부 저장
--   3등급: 자유 저장
-- =============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "pglogical";


-- =============================================================
-- 1. DB 사용자 (비밀번호는 Secrets Manager 관리 — 여기서는 생성만)
-- =============================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ecs_patient_user') THEN
        CREATE ROLE ecs_patient_user LOGIN PASSWORD 'CHANGE_ME_BEFORE_PROD';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ecs_staff_user') THEN
        CREATE ROLE ecs_staff_user LOGIN PASSWORD 'CHANGE_ME_BEFORE_PROD';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
        CREATE ROLE keycloak LOGIN PASSWORD 'CHANGE_ME_BEFORE_PROD';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pglogical_repl') THEN
        CREATE ROLE pglogical_repl LOGIN REPLICATION PASSWORD 'CHANGE_ME_BEFORE_PROD';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dump_user') THEN
        CREATE ROLE dump_user LOGIN PASSWORD 'CHANGE_ME_BEFORE_PROD';
    END IF;
END
$$;


-- =============================================================
-- 2. 온프레미스 동기화 테이블 (pglogical 단방향, 읽기 전용)
--    FK 참조원이므로 users보다 먼저 생성
-- =============================================================

-- 2-1. sync_departments
CREATE TABLE IF NOT EXISTS sync_departments (
    department_code VARCHAR(20)  PRIMARY KEY,
    department_name VARCHAR(100),
    is_active       BOOLEAN,
    synced_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ
);
COMMENT ON TABLE sync_departments IS '진료과 정보 (3등급)';

-- 2-2. sync_doctors
CREATE TABLE IF NOT EXISTS sync_doctors (
    doctor_id       UUID        PRIMARY KEY,
    doctor_name     VARCHAR(100),
    department_code VARCHAR(20) REFERENCES sync_departments(department_code),
    is_active       BOOLEAN,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ
);
COMMENT ON TABLE sync_doctors IS '의사 정보 (3등급)';

-- 2-3. sync_patients
-- patient_id_hash = sha256('<PATIENT_HASH_SALT>:' || patient_id::text)
--   온프레미스 patients.patient_id_hash 트리거와 동일한 SALTED SHA-256.
--   SALT 값은 AWS Secrets Manager에서 주입 — 코드·SQL·로그 하드코딩 금지.
-- patient_hash = sha256(patient_id) UNSALTED — 구(舊) v_cloud_* 뷰 호환용 브리지 컬럼.
CREATE TABLE IF NOT EXISTS sync_patients (
    patient_id_hash VARCHAR(64) PRIMARY KEY,  -- SALTED — 온프레미스 patients.patient_id_hash 동일 방식
    birth_year      SMALLINT,                 -- 출생연도 (YYYY) — 비식별
    gender_code     CHAR(1) CHECK (gender_code IN ('M','F','U')),
    created_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    phone_hash      VARCHAR(64),              -- sha256(phone_number) — 포털 본인확인용, 원본 미저장
    patient_hash    VARCHAR(64)               -- UNSALTED — 레거시 조인 브리지
);
COMMENT ON TABLE sync_patients IS 'EMR 동기화 환자 기본정보 — 1등급 PII(성명·주민번호·전화번호) 제외, SALTED 해시/비식별만 보관';
CREATE INDEX IF NOT EXISTS idx_sync_pat_hash   ON sync_patients(patient_hash);
CREATE INDEX IF NOT EXISTS idx_sync_pat_verify ON sync_patients(birth_year, gender_code, phone_hash);

-- 2-4. sync_encounters
-- patient_id_hash: SALTED — sync_patients FK. (구 patient_hash UNSALTED 컬럼은 폐기됨)
-- encounter_type: 'OPD' | 'ADMISSION' | 'SURGERY_PRECHECK'
-- status_code:    'OPEN' | 'CLOSED' | 'CANCELLED'
CREATE TABLE IF NOT EXISTS sync_encounters (
    encounter_id    VARCHAR(36) PRIMARY KEY,
    patient_id_hash VARCHAR(64) NOT NULL REFERENCES sync_patients(patient_id_hash),
    encounter_type  VARCHAR(30) CONSTRAINT chk_sync_enc_type   CHECK (encounter_type IN ('OPD','ADMISSION','SURGERY_PRECHECK')),
    department_code VARCHAR(20) REFERENCES sync_departments(department_code),
    doctor_id       UUID        REFERENCES sync_doctors(doctor_id),
    visit_date      DATE,
    status_code     VARCHAR(20) CONSTRAINT chk_sync_enc_status CHECK (status_code IN ('OPEN','CLOSED','CANCELLED')),
    created_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sync_enc_date           ON sync_encounters(visit_date);
CREATE INDEX IF NOT EXISTS idx_sync_enc_patient        ON sync_encounters(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_sync_encounters_patient ON sync_encounters(patient_id_hash);  -- 중복 인덱스 (라이브 DB 동일 — 정리 후보)
CREATE INDEX IF NOT EXISTS idx_sync_encounters_doctor  ON sync_encounters(doctor_id);

-- 2-5. sync_diagnoses
CREATE TABLE IF NOT EXISTS sync_diagnoses (
    diagnosis_id    VARCHAR(36) PRIMARY KEY,
    encounter_id    VARCHAR(36) REFERENCES sync_encounters(encounter_id),
    patient_id_hash VARCHAR(64) NOT NULL REFERENCES sync_patients(patient_id_hash),
    diagnosis_code  VARCHAR(20),
    is_primary      BOOLEAN,
    diagnosed_at    TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sync_diag_patient      ON sync_diagnoses(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_sync_diagnoses_patient ON sync_diagnoses(patient_id_hash);  -- 중복 인덱스 (라이브 DB 동일 — 정리 후보)

-- 2-6. sync_allergies
-- ※ allergy_name(원문) 컬럼이 라이브 DB에 존재 — 1등급 원문 저장 금지 원칙과 상충.
--    동기화 파이프라인 변경 시 추가된 것으로 보임. 보안 검토 필요.
CREATE TABLE IF NOT EXISTS sync_allergies (
    allergy_id      VARCHAR(36) PRIMARY KEY,
    patient_id_hash VARCHAR(64) NOT NULL REFERENCES sync_patients(patient_id_hash),
    severity_code   VARCHAR(10),
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    allergy_name    VARCHAR
);
CREATE INDEX IF NOT EXISTS idx_sync_allergies_patient ON sync_allergies(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_sync_allergy_patient   ON sync_allergies(patient_id_hash);  -- 중복 인덱스 (라이브 DB 동일 — 정리 후보)

-- 2-7. sync_surgery_histories
-- ※ surgery_name(원문)·surgery_date(전체 일자) 컬럼이 라이브 DB에 존재 —
--    구(舊) surgery_code + YYYY-MM 비식별 원칙과 상충. 보안 검토 필요.
CREATE TABLE IF NOT EXISTS sync_surgery_histories (
    surgery_history_id VARCHAR(36) PRIMARY KEY,
    patient_id_hash    VARCHAR(64) NOT NULL REFERENCES sync_patients(patient_id_hash),
    surgery_date       DATE,
    synced_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    surgery_name       VARCHAR
);
CREATE INDEX IF NOT EXISTS idx_sync_surgery_patient ON sync_surgery_histories(patient_id_hash);

-- 2-8. sync_wards
CREATE TABLE IF NOT EXISTS sync_wards (
    ward_id        UUID        PRIMARY KEY,
    ward_name      VARCHAR(100),
    room_type      VARCHAR(20),  -- 'single', 'double', 'shared'
    total_beds     SMALLINT,
    available_beds SMALLINT,
    synced_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- 2-9. sync_logs — 동기화 배치 실행 이력
CREATE TABLE IF NOT EXISTS sync_logs (
    id            SERIAL      PRIMARY KEY,
    mode          VARCHAR(20),
    status        VARCHAR(20),
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    attempts      INTEGER     DEFAULT 1,
    synced_counts TEXT
);


-- =============================================================
-- 3. RBAC — 역할 / 권한 (ISMS-P 2.5.4)
-- =============================================================

-- 3-1. roles
CREATE TABLE IF NOT EXISTS roles (
    role_id     SERIAL       PRIMARY KEY,
    role_code   VARCHAR(30)  NOT NULL UNIQUE,
    role_name   VARCHAR(100) NOT NULL,
    description TEXT,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE roles IS '시스템 역할 — RBAC';

-- 3-2. permissions
CREATE TABLE IF NOT EXISTS permissions (
    permission_id   SERIAL       PRIMARY KEY,
    permission_code VARCHAR(50)  NOT NULL UNIQUE,
    permission_name VARCHAR(100) NOT NULL,
    category        VARCHAR(30),
    description     TEXT
);

-- 3-3. role_permissions
CREATE TABLE IF NOT EXISTS role_permissions (
    role_id       INTEGER NOT NULL REFERENCES roles(role_id)             ON DELETE CASCADE,
    permission_id INTEGER NOT NULL REFERENCES permissions(permission_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

-- 3-4. menus
CREATE TABLE IF NOT EXISTS menus (
    menu_id    SERIAL       PRIMARY KEY,
    menu_code  VARCHAR(50)  NOT NULL UNIQUE,
    menu_name  VARCHAR(100) NOT NULL,
    menu_url   VARCHAR(200),
    parent_id  INTEGER      REFERENCES menus(menu_id),
    sort_order INTEGER      NOT NULL DEFAULT 0,
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE
);

-- 3-5. role_menus
CREATE TABLE IF NOT EXISTS role_menus (
    role_id INTEGER NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    menu_id INTEGER NOT NULL REFERENCES menus(menu_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, menu_id)
);


-- =============================================================
-- 4. 인증 (ISMS-P 2.5.1 / 2.5.3)
-- =============================================================

-- 4-1. users
-- member_number: 회원번호 로그인 도입으로 추가 — email은 NULL 허용으로 완화
-- doctor_id / display_name / synced_at: 온프레미스 직원 계정 동기화용
CREATE TABLE IF NOT EXISTS users (
    user_id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    email                VARCHAR(255) CONSTRAINT uq_users_email UNIQUE,
    password_hash        VARCHAR(255) NOT NULL,
    doctor_id            UUID,          -- sync_doctors.doctor_id (논리적 참조만, FK 없음)
    is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
    failed_login_cnt     SMALLINT     NOT NULL DEFAULT 0,
    locked_until         TIMESTAMPTZ,
    last_login_at        TIMESTAMPTZ,
    password_changed_at  TIMESTAMPTZ  DEFAULT now(),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    role_id              INTEGER      NOT NULL REFERENCES roles(role_id),
    password_expires_at  TIMESTAMPTZ,   -- trg_password_expires_at 트리거가 자동 계산 (+90일)
    member_number        VARCHAR(20)  UNIQUE,
    must_change_password BOOLEAN      NOT NULL DEFAULT TRUE,
    display_name         VARCHAR(100),
    patient_id_hash      VARCHAR(64),   -- SALTED SHA-256(patient_id)
    synced_at            TIMESTAMPTZ
);
COMMENT ON COLUMN users.patient_id_hash IS 'SALTED SHA-256(patient_id) — 1등급 원본 저장 불가';
COMMENT ON COLUMN users.doctor_id IS 'sync_doctors.doctor_id 참조 (논리적 참조만)';
CREATE INDEX IF NOT EXISTS idx_users_patient_id_hash ON users(patient_id_hash);

-- 4-2. sessions (Refresh Token)
CREATE TABLE IF NOT EXISTS sessions (
    session_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID        NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    refresh_token_hash  VARCHAR(64) NOT NULL CONSTRAINT uq_sessions_token UNIQUE,
    user_agent          TEXT,
    ip_address          INET,
    expires_at          TIMESTAMPTZ NOT NULL,
    last_used_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_revoked          BOOLEAN     NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_sessions_user_id    ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);

-- 4-3. user_mfa (사용 예정 — 현재 비활성)
CREATE TABLE IF NOT EXISTS user_mfa (
    mfa_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    mfa_type    VARCHAR(10) NOT NULL DEFAULT 'totp',
    secret      VARCHAR(64) NOT NULL,
    is_active   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified_at TIMESTAMPTZ
);

-- 4-4. password_policy (ISMS-P 2.5.3)
CREATE TABLE IF NOT EXISTS password_policy (
    policy_id         SERIAL       PRIMARY KEY,
    min_length        INTEGER      NOT NULL DEFAULT 8,
    require_uppercase BOOLEAN      NOT NULL DEFAULT TRUE,
    require_lowercase BOOLEAN      NOT NULL DEFAULT TRUE,
    require_digit     BOOLEAN      NOT NULL DEFAULT TRUE,
    require_special   BOOLEAN      NOT NULL DEFAULT TRUE,
    expire_days       INTEGER      NOT NULL DEFAULT 90,
    max_failed_logins INTEGER      NOT NULL DEFAULT 5,
    lockout_minutes   INTEGER      NOT NULL DEFAULT 30,
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_by        UUID         REFERENCES users(user_id)
);

-- 4-5. login_history (ISMS-P 2.5.1)
CREATE TABLE IF NOT EXISTS login_history (
    history_id UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        REFERENCES users(user_id) ON DELETE SET NULL,
    email      VARCHAR(255),
    result     VARCHAR(10) NOT NULL,  -- 'success' | 'fail' | 'locked' (구 CHECK 제약은 라이브에서 제거됨)
    ip_address INET,
    user_agent TEXT,
    event_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_login_history_user  ON login_history(user_id);
CREATE INDEX IF NOT EXISTS idx_login_history_event ON login_history(event_at);


-- =============================================================
-- 5. 예약 (SFR-001)
-- =============================================================

-- 5-1. appointment_types
CREATE TABLE IF NOT EXISTS appointment_types (
    type_id                 SERIAL       PRIMARY KEY,
    type_code               VARCHAR(30)  NOT NULL UNIQUE,
    type_name               VARCHAR(100) NOT NULL,
    requires_previous_visit BOOLEAN      NOT NULL DEFAULT FALSE,
    description             TEXT,
    is_active               BOOLEAN      NOT NULL DEFAULT TRUE,
    sort_order              INTEGER      NOT NULL DEFAULT 0
);

-- 5-2. appointment_statuses
CREATE TABLE IF NOT EXISTS appointment_statuses (
    status_id   SERIAL      PRIMARY KEY,
    status_code VARCHAR(20) NOT NULL UNIQUE,
    status_name VARCHAR(50) NOT NULL,
    is_terminal BOOLEAN     NOT NULL DEFAULT FALSE,
    sort_order  INTEGER     NOT NULL DEFAULT 0
);

-- 5-3. appointments
CREATE TABLE IF NOT EXISTS appointments (
    appointment_id        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_user_id       UUID        NOT NULL REFERENCES users(user_id),
    patient_id_hash       VARCHAR(64) REFERENCES sync_patients(patient_id_hash),
    type_id               INTEGER     NOT NULL REFERENCES appointment_types(type_id),
    status_id             INTEGER     NOT NULL REFERENCES appointment_statuses(status_id),
    department_code       VARCHAR(20) REFERENCES sync_departments(department_code),
    doctor_id             UUID        REFERENCES sync_doctors(doctor_id),
    ward_id               UUID        REFERENCES sync_wards(ward_id),
    room_type_pref        VARCHAR(20),
    has_chronic_condition BOOLEAN,
    appointment_date      DATE        NOT NULL,
    appointment_time      TIME        NOT NULL,
    confirmed_at          TIMESTAMPTZ,
    confirmed_by          UUID        REFERENCES users(user_id),
    cancelled_at          TIMESTAMPTZ,
    cancelled_by          UUID        REFERENCES users(user_id),
    cancel_reason         VARCHAR(200),
    notes                 TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_appointments_patient ON appointments(patient_user_id);
CREATE INDEX IF NOT EXISTS idx_appointments_doctor  ON appointments(doctor_id);
CREATE INDEX IF NOT EXISTS idx_appointments_date    ON appointments(appointment_date);
CREATE INDEX IF NOT EXISTS idx_appointments_status  ON appointments(status_id);

-- 5-4. appointment_history
CREATE TABLE IF NOT EXISTS appointment_history (
    history_id     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id UUID        NOT NULL REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    changed_by     UUID        REFERENCES users(user_id),
    prev_status_id INTEGER     REFERENCES appointment_statuses(status_id),
    new_status_id  INTEGER     REFERENCES appointment_statuses(status_id),
    prev_date      DATE,
    new_date       DATE,
    prev_time      TIME,
    new_time       TIME,
    change_reason  VARCHAR(200),
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =============================================================
-- 6. 알림 (AWS SES)
-- =============================================================

-- 6-1. notification_types
CREATE TABLE IF NOT EXISTS notification_types (
    notification_type_id SERIAL       PRIMARY KEY,
    type_code            VARCHAR(30)  NOT NULL UNIQUE,
    type_name            VARCHAR(100) NOT NULL,
    email_subject_tmpl   TEXT,
    email_body_tmpl      TEXT,
    is_active            BOOLEAN      NOT NULL DEFAULT TRUE
);

-- 6-2. notifications
CREATE TABLE IF NOT EXISTS notifications (
    notification_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              UUID        NOT NULL REFERENCES users(user_id),
    notification_type_id INTEGER     REFERENCES notification_types(notification_type_id),
    appointment_id       UUID        REFERENCES appointments(appointment_id),
    channel              VARCHAR(20) NOT NULL DEFAULT 'email',
    status               VARCHAR(20) NOT NULL DEFAULT 'pending',  -- 'pending' | 'sent' | 'failed' (구 CHECK 제약은 라이브에서 제거됨)
    sent_at              TIMESTAMPTZ,
    error_message        TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_appt ON notifications(appointment_id);


-- =============================================================
-- 7. 감사 로그 (ISMS-P 2.9.1)
-- =============================================================
CREATE TABLE IF NOT EXISTS audit_logs (
    audit_log_id    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID        REFERENCES users(user_id) ON DELETE SET NULL,
    patient_id_hash VARCHAR(64),
    action_type     VARCHAR(20) NOT NULL,
    target_table    VARCHAR(50),
    target_id       UUID,
    source_ip       INET,
    result_code     VARCHAR(20),
    event_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON COLUMN audit_logs.patient_id_hash IS 'SHA-256(patient_id) — 원본 저장 금지';
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id  ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event_at ON audit_logs(event_at);
CREATE INDEX IF NOT EXISTS idx_audit_logs_patient  ON audit_logs(patient_id_hash);

-- 7-2. cloudsql_audit_logs — GCP DR(Cloud SQL) 측 감사 로그 수신 테이블
CREATE TABLE IF NOT EXISTS cloudsql_audit_logs (
    audit_log_id    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID,
    patient_id_hash VARCHAR(64),
    action_type     VARCHAR(20) NOT NULL,
    target_table    VARCHAR(50),
    target_id       UUID,
    source_ip       INET,
    result_code     VARCHAR(20),
    event_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =============================================================
-- 8. 트리거 함수
-- =============================================================

-- 8-1. updated_at 자동 갱신
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

-- 8-2. 비밀번호 만료일 자동 계산 (password_changed_at + 90일)
CREATE OR REPLACE FUNCTION update_password_expires_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.password_expires_at := NEW.password_changed_at + INTERVAL '90 days';
    RETURN NEW;
END;
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_updated_at'
    ) THEN
        CREATE TRIGGER trg_users_updated_at
            BEFORE UPDATE ON users
            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_password_expires_at'
    ) THEN
        CREATE TRIGGER trg_password_expires_at
            BEFORE INSERT OR UPDATE OF password_changed_at ON users
            FOR EACH ROW EXECUTE FUNCTION update_password_expires_at();
    END IF;
END;
$$;


-- =============================================================
-- 9. DB 사용자 권한 (라이브 DB 기준)
-- =============================================================

-- ── ecs_patient_user (RDS Proxy 경유 환자 포털 앱) ──────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON
    roles, permissions, role_permissions, menus, role_menus,
    users, sessions,
    sync_patients, sync_doctors, sync_departments, sync_encounters,
    sync_diagnoses, sync_allergies, sync_surgery_histories, sync_logs,
    audit_logs
    TO ecs_patient_user;
GRANT SELECT, INSERT, UPDATE ON
    user_mfa, login_history, password_policy,
    appointment_types, appointment_statuses, appointments, appointment_history,
    notification_types, notifications,
    sync_wards, cloudsql_audit_logs
    TO ecs_patient_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ecs_patient_user;

-- ── ecs_staff_user (RDS Proxy 경유 직원 포털 앱) ────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON
    roles, permissions, role_permissions, menus, role_menus,
    users, sessions,
    sync_patients, sync_doctors, sync_departments, sync_encounters,
    sync_diagnoses, sync_allergies, sync_surgery_histories, sync_logs,
    audit_logs
    TO ecs_staff_user;
GRANT SELECT, INSERT, UPDATE ON
    user_mfa, login_history, password_policy,
    appointment_types, appointments, appointment_history,
    notifications, sync_wards
    TO ecs_staff_user;
GRANT SELECT ON appointment_statuses, notification_types TO ecs_staff_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ecs_staff_user;

-- ── keycloak (SSO — 인증·세션·동기화 테이블만) ──────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON
    users, sessions, audit_logs,
    sync_patients, sync_doctors, sync_departments, sync_encounters,
    sync_diagnoses, sync_allergies, sync_surgery_histories, sync_logs
    TO keycloak;

-- ── pglogical_repl (온프레미스 → AWS 단방향 복제) ───────────────
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pglogical_repl;
GRANT INSERT, UPDATE, DELETE ON
    users, sessions, audit_logs,
    sync_patients, sync_doctors, sync_departments, sync_encounters,
    sync_diagnoses, sync_allergies, sync_surgery_histories, sync_logs
    TO pglogical_repl;

-- ── dump_user (스키마/데이터 백업 — 읽기 전용) ──────────────────
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dump_user;


-- =============================================================
-- 10. 완료 확인
-- =============================================================
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;
