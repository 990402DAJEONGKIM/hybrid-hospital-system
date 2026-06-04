-- =============================================================
-- AWS RDS Aurora PostgreSQL 17.x — 전체 스키마 초기화
-- 대상: hospital-rds 클러스터 (ap-south-2)
-- 실행: psql -h <RDS_ENDPOINT> -U hospital_user -d hospital -f rds_init.sql
--
-- 데이터 민감도 원칙
--   1등급: AWS 저장 불가 (성명, 주민번호, 진단 원문 등)
--   2등급: 비식별화 후 조건부 저장
--   3등급: 자유 저장
-- =============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";


-- =============================================================
-- 1. DB 사용자
-- =============================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_user') THEN
        CREATE ROLE api_user LOGIN PASSWORD 'CHANGE_ME_BEFORE_PROD';
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
    updated_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE sync_departments IS '진료과 정보 (3등급)';

-- 2-2. sync_doctors
CREATE TABLE IF NOT EXISTS sync_doctors (
    doctor_id       UUID        PRIMARY KEY,
    doctor_name     VARCHAR(100),
    department_code VARCHAR(20) REFERENCES sync_departments(department_code),
    is_active       BOOLEAN,
    updated_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE sync_doctors IS '의사 정보 (3등급)';
CREATE INDEX IF NOT EXISTS idx_sync_doctors_dept ON sync_doctors(department_code);

-- 2-3. sync_patients
-- patient_id_hash = sha256('<PATIENT_HASH_SALT>:' || patient_id::text)
--   온프레미스 patients.patient_id_hash 트리거와 동일한 SALTED SHA-256.
--   SALT 값은 AWS Secrets Manager에서 주입 — 코드·SQL·로그 하드코딩 금지.
--   ※ v_cloud_* 뷰의 UNSALTED sha256(patient_id)와 값이 다름.
--      appointments.patient_id_hash(SALTED) ↔ sync_encounters.patient_hash(UNSALTED) 직접 조인 불가.
CREATE TABLE IF NOT EXISTS sync_patients (
    patient_id_hash VARCHAR(64) PRIMARY KEY,  -- sha256('<SALT>:' || patient_id) — 온프레미스 patients.patient_id_hash 동일 방식
    birth_year      SMALLINT,                 -- 출생연도 (YYYY) — 비식별
    gender_code     CHAR(1) CHECK (gender_code IN ('M','F','U')),
    phone_hash      VARCHAR(64),              -- sha256(phone_number) — 포털 본인확인용, 원본 미저장
    created_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE sync_patients IS 'EMR 동기화 환자 기본정보 — 1등급 PII(성명·주민번호·전화번호) 제외, SALTED 해시/비식별만 보관';
CREATE INDEX IF NOT EXISTS idx_sync_pat_verify ON sync_patients(birth_year, gender_code, phone_hash);

-- 2-4. sync_encounters
-- 온프레미스 v_cloud_encounters 뷰 출력 구조를 그대로 수용.
-- patient_hash: encode(sha256(patient_id::text), 'hex') — UNSALTED.
--   sync_patients.patient_id_hash(SALTED)와 값이 다르므로 FK 미설정.
--   appointments.patient_id_hash(SALTED)와 직접 조인 불가 — 앱 레이어에서 처리.
-- encounter_type: 온프레미스 CHECK → 'OPD' | 'ADMISSION' | 'SURGERY_PRECHECK'
-- status_code:    온프레미스 CHECK → 'OPEN' | 'CLOSED' | 'CANCELLED'
-- visit_hour:     date_trunc('hour', visit_datetime)
CREATE TABLE IF NOT EXISTS sync_encounters (
    encounter_id    VARCHAR(36) PRIMARY KEY,
    patient_hash    VARCHAR(64) NOT NULL,
    encounter_type  VARCHAR(30) CHECK (encounter_type IN ('OPD','ADMISSION','SURGERY_PRECHECK')),
    department_code VARCHAR(20) REFERENCES sync_departments(department_code),
    doctor_id       UUID        REFERENCES sync_doctors(doctor_id),
    visit_hour      TIMESTAMPTZ,
    status_code     VARCHAR(20) CHECK (status_code IN ('OPEN','CLOSED','CANCELLED')),
    created_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON COLUMN sync_encounters.patient_hash IS 'sha256(patient_id) UNSALTED — v_cloud_encounters 출력. sync_patients.patient_id_hash(SALTED)와 값 다름.';
CREATE INDEX IF NOT EXISTS idx_sync_enc_patient ON sync_encounters(patient_hash);
CREATE INDEX IF NOT EXISTS idx_sync_enc_doctor  ON sync_encounters(doctor_id);
CREATE INDEX IF NOT EXISTS idx_sync_enc_date    ON sync_encounters(visit_hour);

-- 2-5. sync_diagnoses
-- 온프레미스 v_cloud_diagnoses 뷰 출력 구조를 그대로 수용.
-- patient_hash: UNSALTED — FK 미설정 (sync_patients는 SALTED 사용)
CREATE TABLE IF NOT EXISTS sync_diagnoses (
    diagnosis_id    VARCHAR(36) PRIMARY KEY,
    encounter_id    VARCHAR(36) REFERENCES sync_encounters(encounter_id),
    patient_hash    VARCHAR(64) NOT NULL,
    diagnosis_code  VARCHAR(20),
    is_primary      BOOLEAN,
    diagnosed_at    TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON COLUMN sync_diagnoses.patient_hash IS 'sha256(patient_id) UNSALTED — v_cloud_diagnoses 출력. FK 없음.';
CREATE INDEX IF NOT EXISTS idx_sync_diag_patient ON sync_diagnoses(patient_hash);

-- 2-6. sync_allergies
-- 온프레미스 v_cloud_allergies 뷰 출력 구조를 그대로 수용.
-- allergy_name(원문)은 1등급 — v_cloud_allergies도 전달하지 않음. allergy_code(표준코드)만 수신.
-- severity_code: 온프레미스 CHECK → 'LOW' | 'MEDIUM' | 'HIGH' (대문자)
-- patient_hash: UNSALTED — FK 미설정
CREATE TABLE IF NOT EXISTS sync_allergies (
    allergy_id      VARCHAR(36) PRIMARY KEY,
    patient_hash    VARCHAR(64) NOT NULL,
    allergy_code    VARCHAR(50),
    severity_code   VARCHAR(10) CHECK (severity_code IN ('LOW','MEDIUM','HIGH')),
    is_active       BOOLEAN,
    recorded_at     TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE  sync_allergies              IS '알레르기 정보 — allergy_name(1등급 원문) 저장 금지, allergy_code(표준코드)만 보관';
COMMENT ON COLUMN sync_allergies.patient_hash IS 'sha256(patient_id) UNSALTED — v_cloud_allergies 출력. FK 없음.';
CREATE INDEX IF NOT EXISTS idx_sync_allergy_patient ON sync_allergies(patient_hash);

-- 2-7. sync_surgery_histories
-- 온프레미스 v_cloud_surgery 뷰 출력 구조를 그대로 수용.
-- surgery_name/note(원문)은 1등급 — v_cloud_surgery도 전달하지 않음.
-- surgery_yearmonth: to_char(surgery_date, 'YYYY-MM') 비식별화
-- patient_hash: UNSALTED — FK 미설정
CREATE TABLE IF NOT EXISTS sync_surgery_histories (
    surgery_history_id VARCHAR(36) PRIMARY KEY,
    patient_hash       VARCHAR(64) NOT NULL,
    surgery_code       VARCHAR(50),
    surgery_yearmonth  VARCHAR(7),
    synced_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE  sync_surgery_histories              IS '수술 이력 — surgery_name·note(1등급 원문) 저장 금지, surgery_code + YYYY-MM만 보관';
COMMENT ON COLUMN sync_surgery_histories.patient_hash IS 'sha256(patient_id) UNSALTED — v_cloud_surgery 출력. FK 없음.';
CREATE INDEX IF NOT EXISTS idx_sync_surgery_patient ON sync_surgery_histories(patient_hash);

-- 2-8. sync_wards
CREATE TABLE IF NOT EXISTS sync_wards (
    ward_id        UUID        PRIMARY KEY,
    ward_name      VARCHAR(100),
    room_type      VARCHAR(20),  -- 'single', 'double', 'shared'
    total_beds     SMALLINT,
    available_beds SMALLINT,
    synced_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
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
    role_id       INTEGER NOT NULL REFERENCES roles(role_id)       ON DELETE CASCADE,
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

-- 4-1. users (role_id FK 방식 — roles 테이블 생성 후)
CREATE TABLE IF NOT EXISTS users (
    user_id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    email               VARCHAR(255) NOT NULL UNIQUE,
    password_hash       VARCHAR(255) NOT NULL,
    role_id             INTEGER      NOT NULL REFERENCES roles(role_id),
    patient_id_hash     VARCHAR(64),   -- SHA-256(patient_id)
    doctor_id           UUID,          -- sync_doctors.doctor_id (FK 없음)
    is_active           BOOLEAN      NOT NULL DEFAULT TRUE,
    failed_login_cnt    SMALLINT     NOT NULL DEFAULT 0,
    locked_until        TIMESTAMPTZ,
    last_login_at       TIMESTAMPTZ,
    password_changed_at TIMESTAMPTZ  DEFAULT now(),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON COLUMN users.patient_id_hash IS 'SHA-256(patient_id) — 1등급 원본 저장 불가';
COMMENT ON COLUMN users.doctor_id IS 'sync_doctors.doctor_id 참조 (논리적 참조만)';

CREATE INDEX IF NOT EXISTS idx_users_email          ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_patient_hash   ON users(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_users_role_id        ON users(role_id);

-- 4-2. sessions (Refresh Token)
CREATE TABLE IF NOT EXISTS sessions (
    session_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID        NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    refresh_token_hash  VARCHAR(64) NOT NULL UNIQUE,
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
    result     VARCHAR(10) NOT NULL CHECK (result IN ('success','fail','locked')),
    ip_address INET,
    user_agent TEXT,
    event_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_login_history_user_id  ON login_history(user_id);
CREATE INDEX IF NOT EXISTS idx_login_history_event_at ON login_history(event_at);
CREATE INDEX IF NOT EXISTS idx_login_history_email    ON login_history(email);


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
CREATE INDEX IF NOT EXISTS idx_appt_patient_hash ON appointments(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_appt_patient_uid  ON appointments(patient_user_id);
CREATE INDEX IF NOT EXISTS idx_appt_doctor       ON appointments(doctor_id);
CREATE INDEX IF NOT EXISTS idx_appt_date         ON appointments(appointment_date);
CREATE INDEX IF NOT EXISTS idx_appt_status       ON appointments(status_id);

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
CREATE INDEX IF NOT EXISTS idx_appt_history_appt ON appointment_history(appointment_id);


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
    status               VARCHAR(20) NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending','sent','failed')),
    sent_at              TIMESTAMPTZ,
    error_message        TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notif_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notif_appt_id ON notifications(appointment_id);


-- =============================================================
-- 7. 감사 로그 (ISMS-P 2.9.1)
-- =============================================================
CREATE TABLE IF NOT EXISTS audit_logs (
    audit_log_id    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID        REFERENCES users(user_id) ON DELETE SET NULL,
    patient_id_hash VARCHAR(64),
    action_type     VARCHAR(50) NOT NULL,
    target_table    VARCHAR(50),
    target_id       UUID,
    source_ip       INET,
    result_code     VARCHAR(20),
    event_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON COLUMN audit_logs.patient_id_hash IS 'SHA-256(patient_id) — 원본 저장 금지';
CREATE INDEX IF NOT EXISTS idx_audit_user_id  ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_event_at ON audit_logs(event_at);
CREATE INDEX IF NOT EXISTS idx_audit_patient  ON audit_logs(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_audit_action   ON audit_logs(action_type);


-- =============================================================
-- 8. updated_at 자동 갱신 트리거
-- =============================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
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
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_appointments_updated_at'
    ) THEN
        CREATE TRIGGER trg_appointments_updated_at
            BEFORE UPDATE ON appointments
            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;
END;
$$;


-- =============================================================
-- 9. DB 사용자 권한
-- =============================================================

-- ── ecs_patient_user (RDS Proxy 경유 환자 포털 앱 유저) ──────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ecs_patient_user') THEN
        CREATE ROLE ecs_patient_user LOGIN PASSWORD 'CHANGE_ME_BEFORE_PROD';
    END IF;
END
$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON roles, permissions, role_permissions, menus, role_menus TO ecs_patient_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON users          TO ecs_patient_user;
GRANT SELECT, INSERT, UPDATE ON sessions, user_mfa, login_history, password_policy TO ecs_patient_user;
GRANT SELECT, INSERT, UPDATE ON appointment_types      TO ecs_patient_user;
GRANT SELECT                 ON appointment_statuses   TO ecs_patient_user;
GRANT SELECT, INSERT, UPDATE ON appointments           TO ecs_patient_user;
GRANT SELECT, INSERT         ON appointment_history    TO ecs_patient_user;
GRANT SELECT                 ON notification_types     TO ecs_patient_user;
GRANT SELECT, INSERT, UPDATE ON notifications          TO ecs_patient_user;
GRANT SELECT, INSERT, UPDATE ON sync_patients, sync_doctors, sync_departments  TO ecs_patient_user;
GRANT SELECT, INSERT, UPDATE ON sync_encounters, sync_diagnoses, sync_allergies TO ecs_patient_user;
GRANT SELECT, INSERT, UPDATE ON sync_surgery_histories, sync_wards             TO ecs_patient_user;
GRANT INSERT ON audit_logs TO ecs_patient_user;
REVOKE UPDATE, DELETE ON audit_logs FROM ecs_patient_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ecs_patient_user;

-- ── api_user (로컬 개발 / 레거시) ────────────────────────────────
-- =============================================================
-- (구) api_user 권한
-- =============================================================
-- RBAC 참조 (관리자 역할/권한/메뉴 CRUD 포함)
GRANT SELECT, INSERT, UPDATE, DELETE ON roles              TO api_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON permissions        TO api_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON role_permissions   TO api_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON menus              TO api_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON role_menus         TO api_user;

-- 인증
GRANT SELECT, INSERT, UPDATE, DELETE ON users          TO api_user;
GRANT SELECT, INSERT, UPDATE ON sessions       TO api_user;
GRANT SELECT, INSERT, UPDATE ON user_mfa       TO api_user;
GRANT SELECT, INSERT, UPDATE ON login_history  TO api_user;
GRANT SELECT, INSERT, UPDATE ON password_policy TO api_user;

-- 예약
GRANT SELECT, INSERT, UPDATE ON appointment_types    TO api_user;
GRANT SELECT                 ON appointment_statuses  TO api_user;
GRANT SELECT, INSERT, UPDATE ON appointments         TO api_user;
GRANT SELECT, INSERT         ON appointment_history  TO api_user;

-- 알림
GRANT SELECT                 ON notification_types TO api_user;
GRANT SELECT, INSERT, UPDATE ON notifications     TO api_user;

-- 동기화 테이블 (읽기 + UPSERT)
GRANT SELECT, INSERT, UPDATE ON sync_patients          TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_doctors           TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_departments       TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_encounters        TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_diagnoses         TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_allergies         TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_surgery_histories TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_wards             TO api_user;

-- 감사 로그 (INSERT 전용 — 변조 방지)
GRANT INSERT ON audit_logs TO api_user;
REVOKE UPDATE, DELETE ON audit_logs FROM api_user;

-- SERIAL 시퀀스 사용 권한
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO api_user;


-- =============================================================
-- 10. 완료 확인
-- =============================================================
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;
