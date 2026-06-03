-- =============================================================
-- AWS RDS 로컬 개발 스키마 (hospital)
-- 실제 AWS DB 기준 — docker-compose db 초기화용
-- =============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ── api_user ──────────────────────────────────────────────────
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_user') THEN
        CREATE ROLE api_user LOGIN PASSWORD 'api_password';
    END IF;
END $$;


-- =============================================================
-- RBAC
-- =============================================================

CREATE TABLE IF NOT EXISTS roles (
    role_id     SERIAL       PRIMARY KEY,
    role_code   VARCHAR(30)  NOT NULL UNIQUE,
    role_name   VARCHAR(100) NOT NULL,
    description TEXT,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS permissions (
    permission_id   SERIAL       PRIMARY KEY,
    permission_code VARCHAR(50)  NOT NULL UNIQUE,
    permission_name VARCHAR(100) NOT NULL,
    category        VARCHAR(30),
    description     TEXT
);

CREATE TABLE IF NOT EXISTS menus (
    menu_id    SERIAL       PRIMARY KEY,
    menu_code  VARCHAR(50)  NOT NULL UNIQUE,
    menu_name  VARCHAR(100) NOT NULL,
    menu_url   VARCHAR(200),
    parent_id  INTEGER      REFERENCES menus(menu_id),
    sort_order INTEGER      NOT NULL DEFAULT 0,
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS role_permissions (
    role_id       INTEGER NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    permission_id INTEGER NOT NULL REFERENCES permissions(permission_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE IF NOT EXISTS role_menus (
    role_id INTEGER NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    menu_id INTEGER NOT NULL REFERENCES menus(menu_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, menu_id)
);


-- =============================================================
-- 인증
-- =============================================================

CREATE TABLE IF NOT EXISTS users (
    user_id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    email                VARCHAR(255),
    password_hash        VARCHAR(255) NOT NULL,
    doctor_id            UUID,
    is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
    failed_login_cnt     SMALLINT     NOT NULL DEFAULT 0,
    locked_until         TIMESTAMPTZ,
    last_login_at        TIMESTAMPTZ,
    password_changed_at  TIMESTAMPTZ  DEFAULT now(),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    role_id              INTEGER      NOT NULL REFERENCES roles(role_id),
    password_expires_at  TIMESTAMPTZ,
    member_number        VARCHAR(20)  UNIQUE,
    patient_id_hash      VARCHAR(64),
    must_change_password BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_users_email         ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_member_number ON users(member_number);
CREATE INDEX IF NOT EXISTS idx_users_role_id       ON users(role_id);

CREATE TABLE IF NOT EXISTS sessions (
    session_id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            UUID         NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    refresh_token_hash VARCHAR(64)  NOT NULL UNIQUE,
    user_agent         TEXT,
    ip_address         INET,
    expires_at         TIMESTAMPTZ  NOT NULL,
    last_used_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    is_revoked         BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_sessions_user_id    ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);

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

CREATE TABLE IF NOT EXISTS login_history (
    history_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID         REFERENCES users(user_id) ON DELETE SET NULL,
    email      VARCHAR(255),
    result     VARCHAR(10)  NOT NULL,
    ip_address INET,
    user_agent TEXT,
    event_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_login_history_email    ON login_history(email);
CREATE INDEX IF NOT EXISTS idx_login_history_event_at ON login_history(event_at);


-- =============================================================
-- 온프레미스 동기화 테이블 (읽기 전용 수신)
-- =============================================================

CREATE TABLE IF NOT EXISTS sync_departments (
    department_code VARCHAR(20)  PRIMARY KEY,
    department_name VARCHAR(100),
    is_active       BOOLEAN,
    updated_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sync_doctors (
    doctor_id       UUID        PRIMARY KEY,
    doctor_name     VARCHAR(100),
    department_code VARCHAR(20) REFERENCES sync_departments(department_code),
    is_active       BOOLEAN,
    updated_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_doctors_dept ON sync_doctors(department_code);

-- patient_id_hash = sha256('LOCAL_SALT:' || patient_id) — 로컬 테스트용
CREATE TABLE IF NOT EXISTS sync_patients (
    patient_id_hash VARCHAR(64)  PRIMARY KEY,
    birth_year      SMALLINT,
    gender_code     CHAR(1)      CHECK (gender_code IN ('M','F','U')),
    phone_hash      VARCHAR(64),
    patient_hash    VARCHAR(64),
    created_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_pat_verify ON sync_patients(birth_year, gender_code, phone_hash);

CREATE TABLE IF NOT EXISTS sync_encounters (
    encounter_id    VARCHAR(36)  PRIMARY KEY,
    patient_id_hash VARCHAR(64)  NOT NULL,
    encounter_type  VARCHAR(30),
    department_code VARCHAR(20)  REFERENCES sync_departments(department_code),
    doctor_id       UUID         REFERENCES sync_doctors(doctor_id),
    visit_date      DATE,
    status_code     VARCHAR(20),
    created_at      TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_enc_patient ON sync_encounters(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_sync_enc_doctor  ON sync_encounters(doctor_id);
CREATE INDEX IF NOT EXISTS idx_sync_enc_date    ON sync_encounters(visit_date);

CREATE TABLE IF NOT EXISTS sync_diagnoses (
    diagnosis_id    VARCHAR(36)  PRIMARY KEY,
    encounter_id    VARCHAR(36)  REFERENCES sync_encounters(encounter_id),
    patient_id_hash VARCHAR(64)  NOT NULL,
    diagnosis_code  VARCHAR(20),
    is_primary      BOOLEAN,
    diagnosed_at    TIMESTAMPTZ,
    synced_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_diag_patient ON sync_diagnoses(patient_id_hash);

CREATE TABLE IF NOT EXISTS sync_allergies (
    allergy_id      VARCHAR(36)  PRIMARY KEY,
    patient_id_hash VARCHAR(64)  NOT NULL,
    severity_code   VARCHAR(10),
    allergy_name    VARCHAR(200),
    synced_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_allergy_patient ON sync_allergies(patient_id_hash);

CREATE TABLE IF NOT EXISTS sync_surgery_histories (
    surgery_history_id VARCHAR(36)  PRIMARY KEY,
    patient_id_hash    VARCHAR(64)  NOT NULL,
    surgery_date       DATE,
    surgery_name       VARCHAR(200),
    synced_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_surgery_patient ON sync_surgery_histories(patient_id_hash);

CREATE TABLE IF NOT EXISTS sync_wards (
    ward_id        UUID         PRIMARY KEY,
    ward_name      VARCHAR(100),
    room_type      VARCHAR(20),
    total_beds     SMALLINT,
    available_beds SMALLINT,
    synced_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sync_logs (
    id           SERIAL       PRIMARY KEY,
    mode         VARCHAR(20),
    status       VARCHAR(20),
    started_at   TIMESTAMPTZ,
    finished_at  TIMESTAMPTZ,
    attempts     INTEGER      DEFAULT 1,
    synced_counts TEXT
);


-- =============================================================
-- 예약
-- =============================================================

CREATE TABLE IF NOT EXISTS appointment_types (
    type_id                 SERIAL       PRIMARY KEY,
    type_code               VARCHAR(30)  NOT NULL UNIQUE,
    type_name               VARCHAR(100) NOT NULL,
    requires_previous_visit BOOLEAN      NOT NULL DEFAULT FALSE,
    description             TEXT,
    is_active               BOOLEAN      NOT NULL DEFAULT TRUE,
    sort_order              INTEGER      NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS appointment_statuses (
    status_id   SERIAL       PRIMARY KEY,
    status_code VARCHAR(20)  NOT NULL UNIQUE,
    status_name VARCHAR(50)  NOT NULL,
    is_terminal BOOLEAN      NOT NULL DEFAULT FALSE,
    sort_order  INTEGER      NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS appointments (
    appointment_id        UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_user_id       UUID         NOT NULL REFERENCES users(user_id),
    patient_id_hash       VARCHAR(64)  REFERENCES sync_patients(patient_id_hash),
    type_id               INTEGER      NOT NULL REFERENCES appointment_types(type_id),
    status_id             INTEGER      NOT NULL REFERENCES appointment_statuses(status_id),
    department_code       VARCHAR(20)  REFERENCES sync_departments(department_code),
    doctor_id             UUID         REFERENCES sync_doctors(doctor_id),
    ward_id               UUID         REFERENCES sync_wards(ward_id),
    room_type_pref        VARCHAR(20),
    has_chronic_condition BOOLEAN,
    appointment_date      DATE         NOT NULL,
    appointment_time      TIME         NOT NULL,
    confirmed_at          TIMESTAMPTZ,
    confirmed_by          UUID         REFERENCES users(user_id),
    cancelled_at          TIMESTAMPTZ,
    cancelled_by          UUID         REFERENCES users(user_id),
    cancel_reason         VARCHAR(200),
    notes                 TEXT,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_appt_patient_hash ON appointments(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_appt_patient_uid  ON appointments(patient_user_id);
CREATE INDEX IF NOT EXISTS idx_appt_doctor       ON appointments(doctor_id);
CREATE INDEX IF NOT EXISTS idx_appt_date         ON appointments(appointment_date);
CREATE INDEX IF NOT EXISTS idx_appt_status       ON appointments(status_id);

CREATE TABLE IF NOT EXISTS appointment_history (
    history_id     UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id UUID         NOT NULL REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    changed_by     UUID         REFERENCES users(user_id),
    prev_status_id INTEGER      REFERENCES appointment_statuses(status_id),
    new_status_id  INTEGER      REFERENCES appointment_statuses(status_id),
    prev_date      DATE,
    new_date       DATE,
    prev_time      TIME,
    new_time       TIME,
    change_reason  VARCHAR(200),
    changed_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_appt_history_appt ON appointment_history(appointment_id);


-- =============================================================
-- 알림
-- =============================================================

CREATE TABLE IF NOT EXISTS notification_types (
    notification_type_id SERIAL       PRIMARY KEY,
    type_code            VARCHAR(30)  NOT NULL UNIQUE,
    type_name            VARCHAR(100) NOT NULL,
    email_subject_tmpl   TEXT,
    email_body_tmpl      TEXT,
    is_active            BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS notifications (
    notification_id      UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              UUID         NOT NULL REFERENCES users(user_id),
    notification_type_id INTEGER      REFERENCES notification_types(notification_type_id),
    appointment_id       UUID         REFERENCES appointments(appointment_id),
    channel              VARCHAR(20)  NOT NULL DEFAULT 'email',
    status               VARCHAR(20)  NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending','sent','failed')),
    sent_at              TIMESTAMPTZ,
    error_message        TEXT,
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notif_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notif_appt_id ON notifications(appointment_id);


-- =============================================================
-- 감사 로그
-- =============================================================

CREATE TABLE IF NOT EXISTS audit_logs (
    audit_log_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID         REFERENCES users(user_id) ON DELETE SET NULL,
    patient_id_hash VARCHAR(64),
    action_type     VARCHAR(50)  NOT NULL,
    target_table    VARCHAR(50),
    target_id       UUID,
    source_ip       INET,
    result_code     VARCHAR(20),
    event_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_user_id  ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_event_at ON audit_logs(event_at);
CREATE INDEX IF NOT EXISTS idx_audit_action   ON audit_logs(action_type);


-- =============================================================
-- updated_at 자동 갱신 트리거
-- =============================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_updated_at') THEN
        CREATE TRIGGER trg_users_updated_at
            BEFORE UPDATE ON users
            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_appointments_updated_at') THEN
        CREATE TRIGGER trg_appointments_updated_at
            BEFORE UPDATE ON appointments
            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;
END $$;


-- =============================================================
-- 권한
-- =============================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON roles, permissions, role_permissions, menus, role_menus TO api_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON users, sessions, login_history, password_policy TO api_user;
GRANT SELECT, INSERT, UPDATE         ON appointment_types, appointments, appointment_history       TO api_user;
GRANT SELECT                         ON appointment_statuses                                       TO api_user;
GRANT SELECT, INSERT, UPDATE         ON notifications, notification_types                         TO api_user;
GRANT SELECT, INSERT, UPDATE         ON sync_patients, sync_doctors, sync_departments             TO api_user;
GRANT SELECT, INSERT, UPDATE         ON sync_encounters, sync_diagnoses, sync_allergies           TO api_user;
GRANT SELECT, INSERT, UPDATE         ON sync_surgery_histories, sync_wards, sync_logs            TO api_user;
GRANT INSERT                         ON audit_logs                                                TO api_user;
REVOKE UPDATE, DELETE ON audit_logs FROM api_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO api_user;
