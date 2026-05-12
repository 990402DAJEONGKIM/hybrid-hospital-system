-- =============================================================
-- AWS RDS Aurora PostgreSQL 17.x — 전체 스키마 초기화
-- 대상: hospital-rds 클러스터 (ap-south-2)
-- 실행: psql -h <RDS_ENDPOINT> -U hospital_user -d hospital -f rds_init.sql
--
-- 데이터 민감도 원칙
--   1등급: AWS 저장 불가 (성명, 주민번호, 진단 원문, chief_complaint 등)
--   2등급: 비식별화 후 조건부 저장
--   3등급: 자유 저장
-- =============================================================

-- ── 확장 ─────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- 향후 검색 인덱스 대비


-- =============================================================
-- 1. 역할(Role) 생성
-- =============================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_user') THEN
        CREATE ROLE api_user LOGIN PASSWORD 'CHANGE_ME_BEFORE_PROD';
    END IF;
END
$$;

COMMENT ON ROLE api_user IS 'EC2 비식별화 API 서버 전용 — 1등급 컬럼 접근 불가';


-- =============================================================
-- 2. 인증 테이블 (온프레미스 ↔ AWS 양방향 동기화)
-- =============================================================

-- 2-1. users
CREATE TABLE IF NOT EXISTS users (
    user_id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    email               VARCHAR(255) NOT NULL,
    password_hash       VARCHAR(255) NOT NULL,       -- bcrypt cost≥12
    role                VARCHAR(10)  NOT NULL
                            CHECK (role IN ('patient', 'doctor', 'admin')),

    -- AWS에는 원본 ID 대신 해시만 저장 (1등급 연결고리 차단)
    patient_id_hash     VARCHAR(64),                 -- SHA-256(patient_id) hex
    doctor_id           UUID,                        -- doctors 테이블 없으므로 FK 없음

    is_active           BOOLEAN      NOT NULL DEFAULT TRUE,
    failed_login_cnt    SMALLINT     NOT NULL DEFAULT 0,
    locked_until        TIMESTAMPTZ,
    last_login_at       TIMESTAMPTZ,
    password_changed_at TIMESTAMPTZ DEFAULT now(),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_users_email UNIQUE (email)
);

COMMENT ON TABLE  users IS '시스템 계정 — 온프레미스와 양방향 동기화';
COMMENT ON COLUMN users.patient_id_hash IS 'SHA-256(온프레미스 patient_id) — 1등급 원본 참조 불가';
COMMENT ON COLUMN users.doctor_id IS '온프레미스 doctors.doctor_id 복사 (FK 없음)';

CREATE INDEX IF NOT EXISTS idx_users_patient_id_hash ON users(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_users_role            ON users(role);

-- 2-2. sessions (Refresh Token)
CREATE TABLE IF NOT EXISTS sessions (
    session_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID        NOT NULL
                            REFERENCES users(user_id) ON DELETE CASCADE,
    refresh_token_hash  VARCHAR(64) NOT NULL,         -- SHA-256 hex
    CONSTRAINT uq_sessions_token UNIQUE (refresh_token_hash),

    user_agent          TEXT,
    ip_address          INET,

    expires_at          TIMESTAMPTZ NOT NULL,
    last_used_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_revoked          BOOLEAN     NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE sessions IS 'Refresh Token 저장소 — 온프레미스와 양방향 동기화';

CREATE INDEX IF NOT EXISTS idx_sessions_user_id    ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);


-- =============================================================
-- 3. 비식별화 동기화 테이블 (온프레미스 → AWS 단방향)
--    EC2 비식별화 API가 v_cloud_* 뷰 읽어서 여기에 UPSERT
-- =============================================================

-- 3-1. sync_patients
--   제거 컬럼: patient_name(1), national_id_encrypted(1), phone_number(1),
--              email(1), address(1)
--   변환: birth_date → birth_year(EXTRACT), patient_id → patient_id_hash
CREATE TABLE IF NOT EXISTS sync_patients (
    patient_id_hash     VARCHAR(64)  PRIMARY KEY,    -- SHA-256(patient_id)
    birth_year          SMALLINT,                    -- EXTRACT(YEAR FROM birth_date)
    gender_code         CHAR(1)      CHECK (gender_code IN ('M','F','U')),
    created_at          TIMESTAMPTZ,
    synced_at           TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE sync_patients IS '비식별화 환자 기본정보 — 1등급 전체 제거';


-- 3-2. sync_departments  (3등급 전체 — 원본 그대로, sync_doctors보다 먼저 생성)
CREATE TABLE IF NOT EXISTS sync_departments (
    department_code     VARCHAR(20)  PRIMARY KEY,
    department_name     VARCHAR(100),
    is_active           BOOLEAN,
    synced_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE sync_departments IS '진료과 정보 (3등급) — 원본 그대로 동기화';


-- 3-3. sync_doctors  (3등급 전체 — 원본 그대로)
CREATE TABLE IF NOT EXISTS sync_doctors (
    doctor_id           UUID        PRIMARY KEY,
    doctor_name         VARCHAR(100),
    department_code     VARCHAR(20)  REFERENCES sync_departments(department_code),
    is_active           BOOLEAN,
    synced_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE sync_doctors IS '의사 정보 (3등급) — 원본 그대로 동기화';


-- 3-4. sync_encounters
--   제거 컬럼: chief_complaint(1등급)
--   변환: patient_id → patient_id_hash, visit_datetime → visit_date(DATE만)
CREATE TABLE IF NOT EXISTS sync_encounters (
    encounter_id        UUID        PRIMARY KEY,
    patient_id_hash     VARCHAR(64) NOT NULL REFERENCES sync_patients(patient_id_hash),
    encounter_type      VARCHAR(30),
    department_code     VARCHAR(20) REFERENCES sync_departments(department_code),
    doctor_id           UUID        REFERENCES sync_doctors(doctor_id),
    visit_date          DATE,                        -- 시각 제거, 날짜만
    status_code         VARCHAR(20),
    created_at          TIMESTAMPTZ,
    synced_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  sync_encounters IS '비식별화 내원 기록 — chief_complaint(1등급) 제거';
COMMENT ON COLUMN sync_encounters.visit_date IS '원본 visit_datetime에서 날짜만 추출';

CREATE INDEX IF NOT EXISTS idx_sync_encounters_patient ON sync_encounters(patient_id_hash);
CREATE INDEX IF NOT EXISTS idx_sync_encounters_doctor  ON sync_encounters(doctor_id);


-- 3-5. sync_diagnoses
--   제거 컬럼: diagnosis_text(1등급 원문 진단명)
--   변환: patient_id → patient_id_hash
CREATE TABLE IF NOT EXISTS sync_diagnoses (
    diagnosis_id        UUID        PRIMARY KEY,
    encounter_id        UUID        REFERENCES sync_encounters(encounter_id),
    patient_id_hash     VARCHAR(64) NOT NULL REFERENCES sync_patients(patient_id_hash),
    diagnosis_code      VARCHAR(20),                 -- ICD-10 코드만 저장
    is_primary          BOOLEAN,
    diagnosed_at        TIMESTAMPTZ,
    synced_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  sync_diagnoses IS '비식별화 진단 정보 — diagnosis_text(1등급) 제거';
COMMENT ON COLUMN sync_diagnoses.diagnosis_code IS 'ICD-10 코드 — 원문 진단명 제거됨';

CREATE INDEX IF NOT EXISTS idx_sync_diagnoses_patient ON sync_diagnoses(patient_id_hash);


-- 3-6. sync_allergies
--   변환: patient_id → patient_id_hash
--   allergy_name: 표준 코드명이므로 2→3등급 처리 (코드+명 둘 다 저장)
CREATE TABLE IF NOT EXISTS sync_allergies (
    allergy_id          UUID        PRIMARY KEY,
    patient_id_hash     VARCHAR(64) NOT NULL REFERENCES sync_patients(patient_id_hash),
    allergy_code        VARCHAR(30),
    allergy_name        VARCHAR(100),               -- 표준 코드명 (비식별 가능)
    severity_code       VARCHAR(20),
    is_active           BOOLEAN,
    recorded_at         TIMESTAMPTZ,
    synced_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE sync_allergies IS '비식별화 알레르기 정보';

CREATE INDEX IF NOT EXISTS idx_sync_allergies_patient ON sync_allergies(patient_id_hash);


-- 3-7. sync_surgery_histories
--   제거 컬럼: note(1등급 자유 기술)
--   변환: patient_id → patient_id_hash
CREATE TABLE IF NOT EXISTS sync_surgery_histories (
    surgery_history_id  UUID        PRIMARY KEY,
    patient_id_hash     VARCHAR(64) NOT NULL REFERENCES sync_patients(patient_id_hash),
    surgery_code        VARCHAR(30),
    surgery_name        VARCHAR(200),
    surgery_date        DATE,
    synced_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  sync_surgery_histories IS '비식별화 수술 이력 — note(1등급) 제거';

CREATE INDEX IF NOT EXISTS idx_sync_surgery_patient ON sync_surgery_histories(patient_id_hash);


-- =============================================================
-- 4. 감사 로그 (AWS 자체 감사 — 온프레미스와 별도 관리)
--    patient_id: SHA-256 해시로만 저장
-- =============================================================
CREATE TABLE IF NOT EXISTS audit_logs (
    audit_log_id        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID        REFERENCES users(user_id) ON DELETE SET NULL,
    patient_id_hash     VARCHAR(64),                -- SHA-256(patient_id)
    action_type         VARCHAR(20) NOT NULL,
    target_table        VARCHAR(50),
    target_id           UUID,
    source_ip           INET,
    result_code         VARCHAR(20),
    event_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  audit_logs IS 'AWS 측 접근 감사 로그 — patient_id 해시화';
COMMENT ON COLUMN audit_logs.patient_id_hash IS 'SHA-256(patient_id) — 원본 ID 저장 금지';

CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id    ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event_at   ON audit_logs(event_at);
CREATE INDEX IF NOT EXISTS idx_audit_logs_patient    ON audit_logs(patient_id_hash);


-- =============================================================
-- 5. updated_at 자동 갱신 트리거
-- =============================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================
-- 6. api_user 권한 (EC2 비식별화 API 전용)
-- =============================================================
-- 인증 테이블: SELECT/INSERT/UPDATE만 (DELETE 불가)
GRANT SELECT, INSERT, UPDATE ON users    TO api_user;
GRANT SELECT, INSERT, UPDATE ON sessions TO api_user;

-- 동기화 테이블: SELECT/INSERT/UPDATE (UPSERT용)
GRANT SELECT, INSERT, UPDATE ON sync_patients          TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_doctors           TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_departments       TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_encounters        TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_diagnoses         TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_allergies         TO api_user;
GRANT SELECT, INSERT, UPDATE ON sync_surgery_histories TO api_user;

-- 감사 로그: INSERT만 (변조 방지)
GRANT INSERT ON audit_logs TO api_user;
REVOKE UPDATE, DELETE ON audit_logs FROM api_user;


-- =============================================================
-- 7. 테이블 생성 순서 재정리 (FK 의존성 확인용 주석)
-- =============================================================
-- 생성 순서:
--   1. sync_departments
--   2. sync_doctors        (→ sync_departments)
--   3. users
--   4. sessions            (→ users)
--   5. sync_patients
--   6. sync_encounters     (→ sync_patients, sync_departments, sync_doctors)
--   7. sync_diagnoses      (→ sync_encounters, sync_patients)
--   8. sync_allergies      (→ sync_patients)
--   9. sync_surgery_histories (→ sync_patients)
--  10. audit_logs          (→ users)


-- =============================================================
-- 8. 완료 확인
-- =============================================================
SELECT
    tablename,
    (SELECT count(*)
     FROM information_schema.columns c
     WHERE c.table_name = t.tablename AND c.table_schema = 'public') AS col_count
FROM (
    VALUES
        ('users'), ('sessions'),
        ('sync_patients'), ('sync_doctors'), ('sync_departments'),
        ('sync_encounters'), ('sync_diagnoses'),
        ('sync_allergies'), ('sync_surgery_histories'),
        ('audit_logs')
) AS t(tablename)
ORDER BY tablename;
