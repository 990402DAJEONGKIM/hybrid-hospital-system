-- =============================================================
-- 온프레미스 HIS DB 스키마 (hospital_onprem)
-- 실제 DB 기준으로 생성 — docker-compose onprem-db 초기화용
-- =============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── 진료과 ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS departments (
    department_code VARCHAR(20)  PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    updated_at      TIMESTAMP    DEFAULT now()
);

-- ── 의사 ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS doctors (
    doctor_id       UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_name     VARCHAR(100) NOT NULL,
    department_code VARCHAR(20)  NOT NULL REFERENCES departments(department_code),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    updated_at      TIMESTAMP    DEFAULT now()
);

-- ── 환자 (1등급 포함 — 온프레미스 전용) ────────────────────
CREATE TABLE IF NOT EXISTS patients (
    patient_id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_name          VARCHAR(100) NOT NULL,
    national_id_encrypted TEXT         NOT NULL,
    birth_date            DATE         NOT NULL,
    gender_code           CHAR(1)      NOT NULL CHECK (gender_code IN ('M','F','U')),
    phone_number          VARCHAR(20)  NOT NULL,
    email                 VARCHAR(200),
    address               TEXT,
    created_at            TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at            TIMESTAMP    NOT NULL DEFAULT now(),
    patient_id_hash       VARCHAR(64)  NOT NULL,
    member_number         VARCHAR(8)   UNIQUE,
    internal_seq          VARCHAR(20)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_patients_patient_id_hash ON patients(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_patients_phone       ON patients(phone_number);
CREATE INDEX IF NOT EXISTS idx_patients_member      ON patients(member_number);

-- patient_id_hash 자동 계산 트리거 (sha256('LOCAL_SALT:' || patient_id))
CREATE OR REPLACE FUNCTION trg_patients_id_hash()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.patient_id_hash := encode(
        digest('LOCAL_SALT:' || NEW.patient_id::text, 'sha256'), 'hex'
    );
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_patients_set_id_hash') THEN
        CREATE TRIGGER trg_patients_set_id_hash
            BEFORE INSERT ON patients
            FOR EACH ROW EXECUTE FUNCTION trg_patients_id_hash();
    END IF;
END $$;

-- ── RBAC — 역할 ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS roles (
    role_id     SERIAL       PRIMARY KEY,
    role_code   VARCHAR(30)  NOT NULL UNIQUE,
    role_name   VARCHAR(100) NOT NULL,
    description TEXT,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    synced_at   TIMESTAMPTZ
);

-- ── RBAC — 권한 ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS permissions (
    permission_id   SERIAL       PRIMARY KEY,
    permission_code VARCHAR(50)  NOT NULL UNIQUE,
    permission_name VARCHAR(100) NOT NULL,
    category        VARCHAR(30),
    description     TEXT,
    synced_at       TIMESTAMPTZ
);

-- ── RBAC — 메뉴 ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS menus (
    menu_id    SERIAL       PRIMARY KEY,
    menu_code  VARCHAR(50)  NOT NULL UNIQUE,
    menu_name  VARCHAR(100) NOT NULL,
    menu_url   VARCHAR(200),
    parent_id  INTEGER      REFERENCES menus(menu_id),
    sort_order INTEGER      NOT NULL DEFAULT 0,
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
    synced_at  TIMESTAMPTZ
);

-- ── 사용자 ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    user_id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    email                VARCHAR(255),
    password_hash        VARCHAR(255) NOT NULL,
    patient_id           UUID         REFERENCES patients(patient_id),
    doctor_id            UUID         REFERENCES doctors(doctor_id),
    is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
    failed_login_cnt     SMALLINT     NOT NULL DEFAULT 0,
    locked_until         TIMESTAMPTZ,
    last_login_at        TIMESTAMPTZ,
    password_changed_at  TIMESTAMPTZ  DEFAULT now(),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    role_id              INTEGER      REFERENCES roles(role_id),
    password_expires_at  TIMESTAMPTZ,
    synced_at            TIMESTAMPTZ,
    member_number        VARCHAR(20)  UNIQUE,
    must_change_password BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_users_email         ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_member_number ON users(member_number);
CREATE INDEX IF NOT EXISTS idx_users_role_id       ON users(role_id);

-- ── RBAC 매핑 ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS role_permissions (
    role_id       INTEGER NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    permission_id INTEGER NOT NULL REFERENCES permissions(permission_id) ON DELETE CASCADE,
    synced_at     TIMESTAMPTZ,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE IF NOT EXISTS role_menus (
    role_id   INTEGER NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    menu_id   INTEGER NOT NULL REFERENCES menus(menu_id) ON DELETE CASCADE,
    synced_at TIMESTAMPTZ,
    PRIMARY KEY (role_id, menu_id)
);

-- ── 세션 ─────────────────────────────────────────────────────
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

CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id);

-- ── 로그인 이력 (ISMS-P 2.9.1) ───────────────────────────────
CREATE TABLE IF NOT EXISTS login_history (
    history_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID         REFERENCES users(user_id) ON DELETE SET NULL,
    email      VARCHAR(255),
    result     VARCHAR(10)  NOT NULL,
    ip_address VARCHAR(50),
    user_agent TEXT,
    event_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    synced_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_login_history_email    ON login_history(email);
CREATE INDEX IF NOT EXISTS idx_login_history_event_at ON login_history(event_at DESC);

-- ── 비밀번호 정책 (ISMS-P 2.5.3) ─────────────────────────────
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
    updated_by        UUID         REFERENCES users(user_id),
    synced_at         TIMESTAMPTZ
);

-- ── 감사 로그 (ISMS-P 2.9.1) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_logs (
    audit_log_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID         REFERENCES users(user_id) ON DELETE SET NULL,
    patient_id   UUID         REFERENCES patients(patient_id) ON DELETE SET NULL,
    action_type  VARCHAR(30)  NOT NULL,
    target_table VARCHAR(60),
    target_id    UUID,
    source_ip    INET,
    result_code  VARCHAR(20),
    event_at     TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_event_at   ON audit_logs(event_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action     ON audit_logs(action_type);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id    ON audit_logs(user_id);

-- ── 진료 방문 ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS encounters (
    encounter_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      UUID         NOT NULL REFERENCES patients(patient_id),
    encounter_type  VARCHAR(30),
    department_code VARCHAR(20)  REFERENCES departments(department_code),
    doctor_id       UUID         REFERENCES doctors(doctor_id),
    visit_datetime  TIMESTAMP,
    chief_complaint TEXT,
    status_code     VARCHAR(20)  NOT NULL DEFAULT 'open',
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP    DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_encounters_patient    ON encounters(patient_id);
CREATE INDEX IF NOT EXISTS idx_encounters_doctor     ON encounters(doctor_id);
CREATE INDEX IF NOT EXISTS idx_encounters_visit      ON encounters(visit_datetime);

-- ── 진단 ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS diagnoses (
    diagnosis_id   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    encounter_id   UUID         NOT NULL REFERENCES encounters(encounter_id),
    patient_id     UUID         NOT NULL REFERENCES patients(patient_id),
    diagnosis_code VARCHAR(20)  NOT NULL,
    diagnosis_text TEXT         NOT NULL,
    is_primary     BOOLEAN      NOT NULL DEFAULT FALSE,
    diagnosed_at   TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at     TIMESTAMP    DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_diagnoses_patient    ON diagnoses(patient_id);
CREATE INDEX IF NOT EXISTS idx_diagnoses_encounter  ON diagnoses(encounter_id);

-- ── 임상 노트 (1등급 전체) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS clinical_notes (
    note_id      UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    encounter_id UUID         NOT NULL REFERENCES encounters(encounter_id),
    patient_id   UUID         NOT NULL REFERENCES patients(patient_id),
    author_type  VARCHAR(20)  NOT NULL,
    note_type    VARCHAR(30)  NOT NULL,
    note_text    TEXT         NOT NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_clinical_notes_patient   ON clinical_notes(patient_id);
CREATE INDEX IF NOT EXISTS idx_clinical_notes_encounter ON clinical_notes(encounter_id);

-- ── 알레르기 ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS allergies (
    allergy_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    UUID         NOT NULL REFERENCES patients(patient_id),
    allergy_code  VARCHAR(50)  NOT NULL,
    allergy_name  TEXT         NOT NULL,
    severity_code VARCHAR(10)  NOT NULL,
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    recorded_at   TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP    DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_allergies_patient ON allergies(patient_id);

-- ── 수술 이력 ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS surgery_histories (
    surgery_history_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id         UUID         NOT NULL REFERENCES patients(patient_id),
    surgery_code       VARCHAR(50)  NOT NULL,
    surgery_name       TEXT         NOT NULL,
    surgery_date       DATE         NOT NULL,
    note               TEXT,
    updated_at         TIMESTAMP    DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_surgery_patient ON surgery_histories(patient_id);

-- ── 병동 ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS wards (
    ward_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    ward_name  VARCHAR(100) NOT NULL,
    room_type  VARCHAR(20)  NOT NULL CHECK (room_type IN ('single','double','shared')),
    total_beds SMALLINT     NOT NULL CHECK (total_beds > 0),
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 병상 배정 ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ward_assignments (
    assignment_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    UUID         NOT NULL REFERENCES patients(patient_id),
    ward_id       UUID         NOT NULL REFERENCES wards(ward_id),
    assigned_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    discharged_at TIMESTAMPTZ,
    status        VARCHAR(20)  NOT NULL DEFAULT 'active' CHECK (status IN ('active','discharged')),
    notes         TEXT
);

CREATE INDEX IF NOT EXISTS idx_ward_assign_patient ON ward_assignments(patient_id);
CREATE INDEX IF NOT EXISTS idx_ward_assign_status  ON ward_assignments(status);

-- ── 예약 유형 (AWS 동기화) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS appointment_types (
    type_id                 SERIAL       PRIMARY KEY,
    type_code               VARCHAR(20)  NOT NULL UNIQUE,
    type_name               VARCHAR(50)  NOT NULL,
    requires_previous_visit BOOLEAN      NOT NULL DEFAULT FALSE,
    description             TEXT,
    is_active               BOOLEAN      NOT NULL DEFAULT TRUE,
    sort_order              INTEGER      NOT NULL DEFAULT 0,
    synced_at               TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 예약 상태 (AWS 동기화) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS appointment_statuses (
    status_id   SERIAL       PRIMARY KEY,
    status_code VARCHAR(20)  NOT NULL UNIQUE,
    status_name VARCHAR(50)  NOT NULL,
    is_terminal BOOLEAN      NOT NULL DEFAULT FALSE,
    sort_order  INTEGER      NOT NULL DEFAULT 0,
    synced_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 예약 (AWS → 온프레미스 동기화) ──────────────────────────
CREATE TABLE IF NOT EXISTS appointments (
    appointment_id        UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id_hash       VARCHAR(64)  NOT NULL,
    type_id               INTEGER      NOT NULL REFERENCES appointment_types(type_id),
    status_id             INTEGER      NOT NULL REFERENCES appointment_statuses(status_id),
    department_code       VARCHAR(20)  REFERENCES departments(department_code),
    doctor_id             UUID         REFERENCES doctors(doctor_id),
    ward_id               UUID         REFERENCES wards(ward_id),
    room_type_pref        VARCHAR(20),
    has_chronic_condition BOOLEAN,
    appointment_date      DATE         NOT NULL,
    appointment_time      TIME         NOT NULL,
    confirmed_at          TIMESTAMPTZ,
    confirmed_by          UUID,
    cancelled_at          TIMESTAMPTZ,
    cancelled_by          UUID,
    cancel_reason         VARCHAR(200),
    notes                 TEXT,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    synced_at             TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_appt_patient_hash ON appointments(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_appt_date         ON appointments(appointment_date);
CREATE INDEX IF NOT EXISTS idx_appt_status       ON appointments(status_id);

-- ── 예약 변경 이력 ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS appointment_history (
    history_id     UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id UUID         NOT NULL REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    changed_by     UUID,
    prev_status_id INTEGER      REFERENCES appointment_statuses(status_id),
    new_status_id  INTEGER      REFERENCES appointment_statuses(status_id),
    prev_date      DATE,
    new_date       DATE,
    prev_time      TIME,
    new_time       TIME,
    change_reason  VARCHAR(200),
    changed_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    synced_at      TIMESTAMPTZ
);

-- ── 알림 유형 ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notification_types (
    notification_type_id SERIAL       PRIMARY KEY,
    type_code            VARCHAR(30)  NOT NULL UNIQUE,
    type_name            VARCHAR(100) NOT NULL,
    email_subject_tmpl   TEXT,
    email_body_tmpl      TEXT,
    is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
    synced_at            TIMESTAMPTZ
);

-- ── 알림 ────────────────────────────────────────────────────
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
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    synced_at            TIMESTAMPTZ
);

-- ── api_user 권한 ─────────────────────────────────────────────
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'api_user') THEN
        CREATE ROLE api_user LOGIN PASSWORD 'api_password';
    END IF;
END $$;

GRANT ALL ON ALL TABLES    IN SCHEMA public TO api_user;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO api_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO api_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO api_user;
