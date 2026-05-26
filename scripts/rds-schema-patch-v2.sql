-- =============================================================
-- AWS RDS — 스키마 패치 v2
--
-- 목적: deidentification-api target 모델 기준으로 sync_* 스키마 정합
--       온프레미스는 수정하지 않는다.
--
-- 실행 방법:
--   psql -h localhost -p <PORT> -U hospital_user -d hospital \
--     -f scripts/rds-schema-patch-v2.sql
--
-- 변경 요약:
--   V2-1. sync_encounters  : patient_hash → patient_id_hash
--                            visit_hour TIMESTAMPTZ → visit_date DATE
--   V2-2. sync_diagnoses   : patient_hash → patient_id_hash
--   V2-3. sync_allergies   : patient_hash → patient_id_hash
--                            allergy_code 제거, allergy_name 추가
--                            severity_code CHECK 제거
--   V2-4. sync_surgery_histories : patient_hash → patient_id_hash
--                                  surgery_yearmonth → surgery_date DATE
--                                  surgery_code 제거, surgery_name 추가
--   V2-5. sync_logs 테이블 생성 (deidentification-api 동기화 기록용)
-- =============================================================


-- =============================================================
-- V2-1. sync_encounters
-- =============================================================

-- 기존 FK/인덱스 제거 (patient_hash 관련)
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'sync_encounters'::regclass
          AND contype = 'f'
          AND pg_get_constraintdef(oid) LIKE '%patient_hash%'
    LOOP
        EXECUTE format('ALTER TABLE sync_encounters DROP CONSTRAINT IF EXISTS %I', r.conname);
    END LOOP;
END $$;

DROP INDEX IF EXISTS idx_sync_enc_patient;

-- patient_hash → patient_id_hash
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sync_encounters' AND column_name = 'patient_hash'
    ) THEN
        ALTER TABLE sync_encounters RENAME COLUMN patient_hash TO patient_id_hash;
    END IF;
END $$;

-- visit_hour TIMESTAMPTZ → visit_date DATE
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sync_encounters' AND column_name = 'visit_hour'
    ) THEN
        ALTER TABLE sync_encounters RENAME COLUMN visit_hour TO visit_date;
        ALTER TABLE sync_encounters
            ALTER COLUMN visit_date TYPE DATE USING visit_date::DATE;
    END IF;
END $$;

-- 인덱스 재생성
DROP INDEX IF EXISTS idx_sync_enc_date;
CREATE INDEX IF NOT EXISTS idx_sync_enc_date    ON sync_encounters(visit_date);
CREATE INDEX IF NOT EXISTS idx_sync_enc_patient ON sync_encounters(patient_id_hash);

-- FK 재생성
ALTER TABLE sync_encounters DROP CONSTRAINT IF EXISTS fk_enc_patient;
ALTER TABLE sync_encounters
    ADD CONSTRAINT fk_enc_patient
    FOREIGN KEY (patient_id_hash) REFERENCES sync_patients(patient_id_hash);


-- =============================================================
-- V2-2. sync_diagnoses
-- =============================================================

DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'sync_diagnoses'::regclass
          AND contype = 'f'
          AND pg_get_constraintdef(oid) LIKE '%patient_hash%'
    LOOP
        EXECUTE format('ALTER TABLE sync_diagnoses DROP CONSTRAINT IF EXISTS %I', r.conname);
    END LOOP;
END $$;

DROP INDEX IF EXISTS idx_sync_diag_patient;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sync_diagnoses' AND column_name = 'patient_hash'
    ) THEN
        ALTER TABLE sync_diagnoses RENAME COLUMN patient_hash TO patient_id_hash;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_sync_diag_patient ON sync_diagnoses(patient_id_hash);

ALTER TABLE sync_diagnoses DROP CONSTRAINT IF EXISTS fk_diag_patient;
ALTER TABLE sync_diagnoses
    ADD CONSTRAINT fk_diag_patient
    FOREIGN KEY (patient_id_hash) REFERENCES sync_patients(patient_id_hash);


-- =============================================================
-- V2-3. sync_allergies
-- =============================================================

-- severity_code CHECK 제거
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'sync_allergies'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%severity_code%'
    LOOP
        EXECUTE format('ALTER TABLE sync_allergies DROP CONSTRAINT IF EXISTS %I', r.conname);
    END LOOP;
END $$;

-- FK 제거
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'sync_allergies'::regclass
          AND contype = 'f'
          AND pg_get_constraintdef(oid) LIKE '%patient_hash%'
    LOOP
        EXECUTE format('ALTER TABLE sync_allergies DROP CONSTRAINT IF EXISTS %I', r.conname);
    END LOOP;
END $$;

DROP INDEX IF EXISTS idx_sync_allergy_patient;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sync_allergies' AND column_name = 'patient_hash'
    ) THEN
        ALTER TABLE sync_allergies RENAME COLUMN patient_hash TO patient_id_hash;
    END IF;
END $$;

-- allergy_code 제거, allergy_name 추가
ALTER TABLE sync_allergies DROP COLUMN IF EXISTS allergy_code;
ALTER TABLE sync_allergies ADD COLUMN IF NOT EXISTS allergy_name VARCHAR;

-- 불필요 컬럼 제거 (deidentification-api 미사용)
ALTER TABLE sync_allergies DROP COLUMN IF EXISTS is_active;
ALTER TABLE sync_allergies DROP COLUMN IF EXISTS recorded_at;

CREATE INDEX IF NOT EXISTS idx_sync_allergy_patient ON sync_allergies(patient_id_hash);

ALTER TABLE sync_allergies DROP CONSTRAINT IF EXISTS fk_allergy_patient;
ALTER TABLE sync_allergies
    ADD CONSTRAINT fk_allergy_patient
    FOREIGN KEY (patient_id_hash) REFERENCES sync_patients(patient_id_hash);


-- =============================================================
-- V2-4. sync_surgery_histories
-- =============================================================

-- FK 제거
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'sync_surgery_histories'::regclass
          AND contype = 'f'
          AND pg_get_constraintdef(oid) LIKE '%patient_hash%'
    LOOP
        EXECUTE format('ALTER TABLE sync_surgery_histories DROP CONSTRAINT IF EXISTS %I', r.conname);
    END LOOP;
END $$;

DROP INDEX IF EXISTS idx_sync_surgery_patient;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sync_surgery_histories' AND column_name = 'patient_hash'
    ) THEN
        ALTER TABLE sync_surgery_histories RENAME COLUMN patient_hash TO patient_id_hash;
    END IF;
END $$;

-- surgery_yearmonth VARCHAR(7) → surgery_date DATE
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sync_surgery_histories' AND column_name = 'surgery_yearmonth'
    ) THEN
        ALTER TABLE sync_surgery_histories
            ALTER COLUMN surgery_yearmonth TYPE DATE
            USING (surgery_yearmonth || '-01')::DATE;
        ALTER TABLE sync_surgery_histories
            RENAME COLUMN surgery_yearmonth TO surgery_date;
    END IF;
END $$;

-- surgery_code 제거, surgery_name 추가
ALTER TABLE sync_surgery_histories DROP COLUMN IF EXISTS surgery_code;
ALTER TABLE sync_surgery_histories ADD COLUMN IF NOT EXISTS surgery_name VARCHAR;

CREATE INDEX IF NOT EXISTS idx_sync_surgery_patient ON sync_surgery_histories(patient_id_hash);

ALTER TABLE sync_surgery_histories DROP CONSTRAINT IF EXISTS fk_surgery_patient;
ALTER TABLE sync_surgery_histories
    ADD CONSTRAINT fk_surgery_patient
    FOREIGN KEY (patient_id_hash) REFERENCES sync_patients(patient_id_hash);


-- =============================================================
-- V2-5. sync_logs 테이블 생성
-- =============================================================
CREATE TABLE IF NOT EXISTS sync_logs (
    id            SERIAL      PRIMARY KEY,
    mode          VARCHAR     NOT NULL,
    status        VARCHAR     NOT NULL,
    started_at    TIMESTAMPTZ NOT NULL,
    finished_at   TIMESTAMPTZ NOT NULL,
    attempts      INTEGER     NOT NULL,
    synced_counts TEXT        NOT NULL
);


-- =============================================================
-- V2-6. 적용 확인
-- =============================================================
SELECT table_name, column_name, data_type, character_maximum_length
FROM information_schema.columns
WHERE table_name IN (
    'sync_encounters', 'sync_diagnoses',
    'sync_allergies', 'sync_surgery_histories', 'sync_logs'
)
ORDER BY table_name, ordinal_position;
