-- =============================================================
-- 온프레미스 HIS DB 스키마 (hospital_onprem)
-- 로컬 개발 전용 — docker/onprem-init.sh 에서 실행
-- =============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── 진료과 ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS departments (
    department_code VARCHAR(20)  PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ── 의사 ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS doctors (
    doctor_id       UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_name     VARCHAR(100) NOT NULL,
    department_code VARCHAR(20)  REFERENCES departments(department_code),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ── 환자 (1등급 포함 — 온프레미스 전용) ────────────────────
CREATE TABLE IF NOT EXISTS patients (
    patient_id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_name          VARCHAR(100),            -- 1등급
    national_id_encrypted VARCHAR(255),            -- 1등급 (프로젝트 미사용)
    phone_number          VARCHAR(20),             -- 1등급
    phone_hash            VARCHAR(64),             -- SHA256(phone_number) — AWS 복제용, phone_number는 복제 금지
    birth_date            DATE,
    gender_code           CHAR(1) CHECK (gender_code IN ('M','F','U')),
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- phone_number 변경 시 phone_hash 자동 계산
CREATE OR REPLACE FUNCTION trg_patients_phone_hash()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.phone_number IS NOT NULL THEN
        NEW.phone_hash := encode(digest(NEW.phone_number, 'sha256'), 'hex');
    ELSE
        NEW.phone_hash := NULL;
    END IF;
    RETURN NEW;
END;
$$;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_patients_set_phone_hash'
    ) THEN
        CREATE TRIGGER trg_patients_set_phone_hash
            BEFORE INSERT OR UPDATE OF phone_number ON patients
            FOR EACH ROW EXECUTE FUNCTION trg_patients_phone_hash();
    END IF;
END $$;

-- ── 진료 방문 ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS encounters (
    encounter_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      UUID         NOT NULL REFERENCES patients(patient_id),
    doctor_id       UUID         REFERENCES doctors(doctor_id),
    department_code VARCHAR(20)  REFERENCES departments(department_code),
    encounter_type  VARCHAR(30),                   -- outpatient_new/return/inpatient/pre_surgery
    chief_complaint TEXT,                           -- 1등급
    visit_datetime  TIMESTAMPTZ,
    status_code     VARCHAR(20)  NOT NULL DEFAULT 'open',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 진단 ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS diagnoses (
    diagnosis_id   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    encounter_id   UUID         REFERENCES encounters(encounter_id),
    patient_id     UUID         NOT NULL REFERENCES patients(patient_id),
    diagnosis_code VARCHAR(20),
    diagnosis_text TEXT,                            -- 1등급
    is_primary     BOOLEAN      NOT NULL DEFAULT FALSE
);

-- ── 임상 노트 (1등급 전체) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS clinical_notes (
    note_id      UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    encounter_id UUID         REFERENCES encounters(encounter_id),
    note_content TEXT,                              -- 1등급
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 알레르기 ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS allergies (
    allergy_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    UUID         NOT NULL REFERENCES patients(patient_id),
    allergy_name  VARCHAR(100),                     -- 1등급 (원문)
    allergy_code  VARCHAR(50),                      -- AWS 복제용 코드
    severity_code VARCHAR(20)
);

-- ── 수술 이력 ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS surgery_histories (
    surgery_history_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id         UUID         NOT NULL REFERENCES patients(patient_id),
    surgery_name       VARCHAR(200),                -- 1등급
    surgery_code       VARCHAR(30),                 -- AWS 복제용 코드
    note               TEXT,                        -- 1등급
    surgery_date       DATE
);

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

-- ── 계정 (온프레미스 마스터 — role은 VARCHAR) ────────────────
CREATE TABLE IF NOT EXISTS users (
    user_id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    email               VARCHAR(255) NOT NULL UNIQUE,
    password_hash       VARCHAR(255) NOT NULL,
    role                VARCHAR(20)  NOT NULL,      -- doctor / nurse / admin
    patient_id          UUID         REFERENCES patients(patient_id),
    doctor_id           UUID         REFERENCES doctors(doctor_id),
    is_active           BOOLEAN      NOT NULL DEFAULT TRUE,
    failed_login_cnt    SMALLINT     NOT NULL DEFAULT 0,
    locked_until        TIMESTAMPTZ,
    last_login_at       TIMESTAMPTZ,
    password_changed_at TIMESTAMPTZ  DEFAULT now(),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
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

-- ── 로그인 이력 (ISMS-P 2.9.1) ───────────────────────────────
CREATE TABLE IF NOT EXISTS login_history (
    history_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID         REFERENCES users(user_id) ON DELETE SET NULL,
    email      VARCHAR(255),
    result     VARCHAR(10)  NOT NULL,               -- success / fail / locked
    ip_address INET,
    user_agent TEXT,
    event_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

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
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 감사 로그 (ISMS-P 2.9.1) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_logs (
    audit_log_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID         REFERENCES users(user_id) ON DELETE SET NULL,
    patient_id   UUID         REFERENCES patients(patient_id) ON DELETE SET NULL,
    action_type  VARCHAR(50)  NOT NULL,
    target_table VARCHAR(50),
    target_id    UUID,
    source_ip    INET,
    result_code  VARCHAR(20),
    event_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 인덱스 ───────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_patients_phone         ON patients(phone_number);
CREATE INDEX IF NOT EXISTS idx_patients_phone_hash    ON patients(phone_hash);
CREATE INDEX IF NOT EXISTS idx_encounters_patient     ON encounters(patient_id);
CREATE INDEX IF NOT EXISTS idx_encounters_doctor      ON encounters(doctor_id);
CREATE INDEX IF NOT EXISTS idx_encounters_visit       ON encounters(visit_datetime);
CREATE INDEX IF NOT EXISTS idx_diagnoses_patient      ON diagnoses(patient_id);
CREATE INDEX IF NOT EXISTS idx_allergies_patient      ON allergies(patient_id);
CREATE INDEX IF NOT EXISTS idx_surgery_patient        ON surgery_histories(patient_id);
CREATE INDEX IF NOT EXISTS idx_ward_assign_patient    ON ward_assignments(patient_id);
CREATE INDEX IF NOT EXISTS idx_ward_assign_status     ON ward_assignments(status);
CREATE INDEX IF NOT EXISTS idx_login_history_email    ON login_history(email);
CREATE INDEX IF NOT EXISTS idx_login_history_event    ON login_history(event_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event       ON audit_logs(event_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action      ON audit_logs(action_type);

-- ── 권한 부여 ─────────────────────────────────────────────────
GRANT ALL ON ALL TABLES    IN SCHEMA public TO api_user;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO api_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO api_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO api_user;
