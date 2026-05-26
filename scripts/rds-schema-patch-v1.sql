-- =============================================================
-- AWS RDS — 스키마 패치 v1
--
-- 목적: 온프레미스 실제 스키마(2026-05-26 덤프 기준)에 맞춰
--       AWS sync_* 테이블 구조를 정렬하고 ISMS-P 하드스톱 위반을 수정한다.
--       온프레미스는 일절 수정하지 않는다.
--
-- 실행 방법:
--   psql -h <RDS_ENDPOINT> -U hospital_user -d hospital -f rds-schema-patch-v1.sql
--
-- 멱등성: IF NOT EXISTS / IF EXISTS / DO $$ 조건 사용, 재실행 안전.
-- 데이터 손실: PATCH 1·2(컬럼 드롭) 적용 시 기존 allergy_name/surgery_name 값 삭제됨.
--
-- 적용 순서:
--   PATCH 1.  [HARD STOP] sync_allergies.allergy_name 제거
--   PATCH 2.  [HARD STOP] sync_surgery_histories.surgery_name 제거
--   PATCH 3.  sync_surgery_histories.surgery_date → surgery_yearmonth VARCHAR(7)
--   PATCH 4.  sync_encounters.visit_date DATE → visit_hour TIMESTAMPTZ
--   PATCH 5.  sync_encounters — encounter_type / status_code CHECK 제약
--   PATCH 6.  sync_allergies — allergy_code/severity_code 길이·CHECK 수정
--   PATCH 7.  sync_surgery_histories.surgery_code 길이 수정
--   PATCH 8.  sync_departments / sync_doctors — updated_at 추가
--   PATCH 9.  [해시 구조] patient_id_hash → patient_hash (FK 제거)
--             sync_encounters / sync_diagnoses / sync_allergies / sync_surgery_histories
--   PATCH 10. 주석·확인 쿼리
-- =============================================================


-- =============================================================
-- PATCH 1. [HARD STOP] sync_allergies.allergy_name 제거
--
-- [WHY] allergy_name은 알레르기 원문(1등급)으로 AWS 저장 금지.
--       온프레미스 v_cloud_allergies도 이 컬럼을 전달하지 않는다.
--       표준코드(allergy_code)만 AWS에 보관한다.
-- =============================================================
ALTER TABLE sync_allergies
    DROP COLUMN IF EXISTS allergy_name;

COMMENT ON TABLE sync_allergies
    IS '알레르기 정보 — allergy_name(1등급 원문) 저장 금지, allergy_code(표준코드)만 보관';


-- =============================================================
-- PATCH 2. [HARD STOP] sync_surgery_histories.surgery_name 제거
--
-- [WHY] surgery_name은 수술명 원문(1등급)으로 AWS 저장 금지.
--       온프레미스 v_cloud_surgery도 surgery_name을 전달하지 않는다.
--       표준코드(surgery_code)만 AWS에 보관한다.
-- =============================================================
ALTER TABLE sync_surgery_histories
    DROP COLUMN IF EXISTS surgery_name;

COMMENT ON TABLE sync_surgery_histories
    IS '수술 이력 — surgery_name·note(1등급 원문) 저장 금지, surgery_code + YYYY-MM만 보관';


-- =============================================================
-- PATCH 3. sync_surgery_histories.surgery_date → surgery_yearmonth
--
-- [WHY] 온프레미스 v_cloud_surgery는 to_char(surgery_date, 'YYYY-MM')으로
--       정확한 날짜를 비식별화하여 전달한다.
--       AWS에서 DATE로 받으면 타입 불일치로 복제가 실패한다.
-- =============================================================
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sync_surgery_histories'
          AND column_name = 'surgery_date'
    ) THEN
        ALTER TABLE sync_surgery_histories
            RENAME COLUMN surgery_date TO surgery_yearmonth;

        ALTER TABLE sync_surgery_histories
            ALTER COLUMN surgery_yearmonth TYPE VARCHAR(7)
            USING to_char(surgery_yearmonth, 'YYYY-MM');
    END IF;
END $$;


-- =============================================================
-- PATCH 4. sync_encounters.visit_date DATE → visit_hour TIMESTAMPTZ
--
-- [WHY] 온프레미스 v_cloud_encounters는 date_trunc('hour', visit_datetime)으로
--       분·초를 제거한 TIMESTAMPTZ를 visit_hour로 전달한다.
--       AWS에서 DATE로 받으면 타입 불일치로 복제가 실패한다.
-- =============================================================
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sync_encounters'
          AND column_name = 'visit_date'
    ) THEN
        ALTER TABLE sync_encounters
            RENAME COLUMN visit_date TO visit_hour;

        ALTER TABLE sync_encounters
            ALTER COLUMN visit_hour TYPE TIMESTAMPTZ
            USING visit_hour::TIMESTAMPTZ;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'sync_encounters'
          AND indexname = 'idx_sync_enc_date'
    ) THEN
        CREATE INDEX idx_sync_enc_date ON sync_encounters(visit_hour);
    END IF;
END $$;


-- =============================================================
-- PATCH 5. sync_encounters — encounter_type / status_code CHECK 추가
--
-- [WHY] 온프레미스 실제 스키마 CHECK 제약:
--       encounter_type IN ('OPD','ADMISSION','SURGERY_PRECHECK')
--       status_code    IN ('OPEN','CLOSED','CANCELLED')
--       기존 AWS 테이블에 제약이 없어 잘못된 값 유입이 가능했다.
-- =============================================================

-- 기존 CHECK 제거 (이름이 다를 수 있으므로 안전하게 처리)
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT conname
        FROM pg_constraint
        WHERE conrelid = 'sync_encounters'::regclass
          AND contype = 'c'
          AND (pg_get_constraintdef(oid) LIKE '%encounter_type%'
            OR pg_get_constraintdef(oid) LIKE '%status_code%')
    LOOP
        EXECUTE format('ALTER TABLE sync_encounters DROP CONSTRAINT IF EXISTS %I', r.conname);
    END LOOP;
END $$;

-- 기존 데이터 정규화: 구 값 → 온프레미스 실제 값
UPDATE sync_encounters SET encounter_type = 'OPD'       WHERE encounter_type IN ('outpatient','outpatient_new','outpatient_return');
UPDATE sync_encounters SET encounter_type = 'ADMISSION'  WHERE encounter_type = 'inpatient';
UPDATE sync_encounters SET encounter_type = 'SURGERY_PRECHECK' WHERE encounter_type = 'pre_surgery';
UPDATE sync_encounters SET status_code = 'CLOSED'        WHERE status_code IN ('completed','complete');
UPDATE sync_encounters SET status_code = 'OPEN'          WHERE status_code = 'pending';
UPDATE sync_encounters SET status_code = 'CANCELLED'     WHERE status_code = 'cancelled';

ALTER TABLE sync_encounters
    ADD CONSTRAINT chk_sync_enc_type
        CHECK (encounter_type IN ('OPD','ADMISSION','SURGERY_PRECHECK'));

ALTER TABLE sync_encounters
    ADD CONSTRAINT chk_sync_enc_status
        CHECK (status_code IN ('OPEN','CLOSED','CANCELLED'));


-- =============================================================
-- PATCH 6. sync_allergies — allergy_code/severity_code 수정
--
-- [WHY] 온프레미스: allergy_code VARCHAR(50), severity_code VARCHAR(10)
--                   CHECK (severity_code IN ('LOW','MEDIUM','HIGH'))
--       AWS 기존:   allergy_code VARCHAR(30), severity_code VARCHAR(20), CHECK 없음
-- =============================================================
ALTER TABLE sync_allergies
    ALTER COLUMN allergy_code TYPE VARCHAR(50);

-- 기존 severity_code 대문자 정규화
UPDATE sync_allergies SET severity_code = UPPER(severity_code)
WHERE severity_code IS NOT NULL AND severity_code != UPPER(severity_code);

DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'sync_allergies'::regclass AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%severity_code%'
    LOOP
        EXECUTE format('ALTER TABLE sync_allergies DROP CONSTRAINT IF EXISTS %I', r.conname);
    END LOOP;
END $$;

ALTER TABLE sync_allergies
    ALTER COLUMN severity_code TYPE VARCHAR(10);

ALTER TABLE sync_allergies
    ADD CONSTRAINT chk_sync_allergy_severity
        CHECK (severity_code IN ('LOW','MEDIUM','HIGH'));


-- =============================================================
-- PATCH 7. sync_surgery_histories.surgery_code 길이 수정
--
-- [WHY] 온프레미스: surgery_code VARCHAR(50). AWS 기존: VARCHAR(30).
-- =============================================================
ALTER TABLE sync_surgery_histories
    ALTER COLUMN surgery_code TYPE VARCHAR(50);


-- =============================================================
-- PATCH 8. sync_departments / sync_doctors — updated_at 추가
--
-- [WHY] 온프레미스에서 레코드 변경 시각을 추적하기 위해 필요.
--       pglogical/DMS 복제 시 변경 행을 식별하는 데 사용한다.
-- =============================================================
ALTER TABLE sync_departments
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;

ALTER TABLE sync_doctors
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;


-- =============================================================
-- PATCH 9. patient_id_hash → patient_hash 컬럼 리네임 + FK 제거
--
-- [WHY] 온프레미스 v_cloud_* 뷰는 UNSALTED sha256(patient_id) 를 'patient_hash'
--       라는 컬럼명으로 출력한다. 기존 AWS sync 테이블은 SALTED hash를 기준으로
--       'patient_id_hash'로 컬럼을 정의하고 sync_patients에 FK를 걸었는데,
--       실제 전달되는 값(UNSALTED)과 FK 참조 대상(SALTED)이 달라 동기화 불가.
--
--       - sync_patients.patient_id_hash  → SALTED (appointments FK용, 변경 없음)
--       - sync_encounters/diagnoses/allergies/surgery_histories
--           patient_id_hash → patient_hash (UNSALTED, FK 제거)
--
--       온프레미스는 수정하지 않는다.
-- =============================================================

DO $$
DECLARE r RECORD;
BEGIN
    -- sync_encounters
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='sync_encounters' AND column_name='patient_id_hash') THEN
        -- FK 제거
        FOR r IN SELECT conname FROM pg_constraint
                 WHERE conrelid='sync_encounters'::regclass AND contype='f'
                   AND pg_get_constraintdef(oid) LIKE '%patient_id_hash%'
        LOOP
            EXECUTE format('ALTER TABLE sync_encounters DROP CONSTRAINT IF EXISTS %I', r.conname);
        END LOOP;
        ALTER TABLE sync_encounters RENAME COLUMN patient_id_hash TO patient_hash;
        DROP INDEX IF EXISTS idx_sync_enc_patient;
        CREATE INDEX IF NOT EXISTS idx_sync_enc_patient ON sync_encounters(patient_hash);
        COMMENT ON COLUMN sync_encounters.patient_hash
            IS 'sha256(patient_id) UNSALTED — v_cloud_encounters 출력. FK 없음.';
    END IF;

    -- sync_diagnoses
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='sync_diagnoses' AND column_name='patient_id_hash') THEN
        FOR r IN SELECT conname FROM pg_constraint
                 WHERE conrelid='sync_diagnoses'::regclass AND contype='f'
                   AND pg_get_constraintdef(oid) LIKE '%patient_id_hash%'
        LOOP
            EXECUTE format('ALTER TABLE sync_diagnoses DROP CONSTRAINT IF EXISTS %I', r.conname);
        END LOOP;
        ALTER TABLE sync_diagnoses RENAME COLUMN patient_id_hash TO patient_hash;
        DROP INDEX IF EXISTS idx_sync_diag_patient;
        CREATE INDEX IF NOT EXISTS idx_sync_diag_patient ON sync_diagnoses(patient_hash);
        COMMENT ON COLUMN sync_diagnoses.patient_hash
            IS 'sha256(patient_id) UNSALTED — v_cloud_diagnoses 출력. FK 없음.';
    END IF;

    -- sync_allergies
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='sync_allergies' AND column_name='patient_id_hash') THEN
        FOR r IN SELECT conname FROM pg_constraint
                 WHERE conrelid='sync_allergies'::regclass AND contype='f'
                   AND pg_get_constraintdef(oid) LIKE '%patient_id_hash%'
        LOOP
            EXECUTE format('ALTER TABLE sync_allergies DROP CONSTRAINT IF EXISTS %I', r.conname);
        END LOOP;
        ALTER TABLE sync_allergies RENAME COLUMN patient_id_hash TO patient_hash;
        DROP INDEX IF EXISTS idx_sync_allergy_patient;
        CREATE INDEX IF NOT EXISTS idx_sync_allergy_patient ON sync_allergies(patient_hash);
        COMMENT ON COLUMN sync_allergies.patient_hash
            IS 'sha256(patient_id) UNSALTED — v_cloud_allergies 출력. FK 없음.';
    END IF;

    -- sync_surgery_histories
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='sync_surgery_histories' AND column_name='patient_id_hash') THEN
        FOR r IN SELECT conname FROM pg_constraint
                 WHERE conrelid='sync_surgery_histories'::regclass AND contype='f'
                   AND pg_get_constraintdef(oid) LIKE '%patient_id_hash%'
        LOOP
            EXECUTE format('ALTER TABLE sync_surgery_histories DROP CONSTRAINT IF EXISTS %I', r.conname);
        END LOOP;
        ALTER TABLE sync_surgery_histories RENAME COLUMN patient_id_hash TO patient_hash;
        DROP INDEX IF EXISTS idx_sync_surgery_patient;
        CREATE INDEX IF NOT EXISTS idx_sync_surgery_patient ON sync_surgery_histories(patient_hash);
        COMMENT ON COLUMN sync_surgery_histories.patient_hash
            IS 'sha256(patient_id) UNSALTED — v_cloud_surgery 출력. FK 없음.';
    END IF;
END $$;

-- sync_patients 주석 갱신
COMMENT ON TABLE sync_patients
    IS 'EMR 동기화 환자 기본정보 — 1등급 PII 제외, SALTED SHA-256 해시/비식별만 보관. SALT = Secrets Manager 관리.';
COMMENT ON COLUMN sync_patients.patient_id_hash
    IS 'sha256(<SALT>:||patient_id) — 온프레미스 patients.patient_id_hash 트리거 동일 방식. appointments FK 기준.';
COMMENT ON COLUMN sync_patients.phone_hash
    IS 'sha256(phone_number) — 포털 본인확인용. 전화번호 원문 AWS 저장 금지(1등급).';


-- =============================================================
-- PATCH 10. sync_patients.patient_hash 브릿지 컬럼 추가
--
-- [WHY] sync_encounters/diagnoses/allergies/surgery_histories 는 PATCH 9에서
--       patient_id_hash(SALTED) → patient_hash(UNSALTED)로 변경됐다.
--       앱 JWT의 pid는 SALTED hash(sync_patients.patient_id_hash) 기준이므로
--       UNSALTED patient_hash로 환자 진료 데이터를 조회하려면 sync_patients를
--       브릿지로 JOIN해야 한다.
--       sync_patients에 UNSALTED patient_hash 컬럼을 추가해 JOIN 경로를 확보한다.
-- =============================================================
ALTER TABLE sync_patients
    ADD COLUMN IF NOT EXISTS patient_hash VARCHAR(64);

CREATE INDEX IF NOT EXISTS idx_sync_pat_hash ON sync_patients(patient_hash);

COMMENT ON COLUMN sync_patients.patient_hash
    IS 'sha256(patient_id) UNSALTED — v_cloud_patients 출력. sync_encounters 등의 patient_hash JOIN 브릿지.';


-- =============================================================
-- PATCH 11. PK 타입 UUID → VARCHAR(36) (온프레미스 스키마 정합)
--
-- [WHY] 온프레미스 sync_* 테이블의 PK 컬럼이 VARCHAR(36)으로 정의되어 있으나
--       AWS는 UUID로 정의되어 있어 pglogical 복제 시 타입 불일치로 실패한다.
--       온프레미스는 수정하지 않으므로 AWS 쪽을 맞춘다.
--
--       대상 컬럼:
--         sync_encounters.encounter_id       UUID → VARCHAR(36)
--         sync_diagnoses.diagnosis_id        UUID → VARCHAR(36)
--         sync_diagnoses.encounter_id        UUID → VARCHAR(36)  (FK)
--         sync_allergies.allergy_id          UUID → VARCHAR(36)
--         sync_surgery_histories.surgery_history_id UUID → VARCHAR(36)
-- =============================================================

-- sync_diagnoses.encounter_id FK 먼저 제거 (encounter_id PK 변경 전)
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'sync_diagnoses'::regclass AND contype = 'f'
          AND pg_get_constraintdef(oid) LIKE '%encounter_id%'
    LOOP
        EXECUTE format('ALTER TABLE sync_diagnoses DROP CONSTRAINT IF EXISTS %I', r.conname);
    END LOOP;
END $$;

-- sync_encounters.encounter_id: UUID → VARCHAR(36)
ALTER TABLE sync_encounters
    ALTER COLUMN encounter_id TYPE VARCHAR(36) USING encounter_id::TEXT;

-- sync_diagnoses.diagnosis_id: UUID → VARCHAR(36)
ALTER TABLE sync_diagnoses
    ALTER COLUMN diagnosis_id TYPE VARCHAR(36) USING diagnosis_id::TEXT;

-- sync_diagnoses.encounter_id: UUID → VARCHAR(36), FK 재설정
ALTER TABLE sync_diagnoses
    ALTER COLUMN encounter_id TYPE VARCHAR(36) USING encounter_id::TEXT;

ALTER TABLE sync_diagnoses
    ADD CONSTRAINT fk_sync_diag_encounter
    FOREIGN KEY (encounter_id) REFERENCES sync_encounters(encounter_id);

-- sync_allergies.allergy_id: UUID → VARCHAR(36)
ALTER TABLE sync_allergies
    ALTER COLUMN allergy_id TYPE VARCHAR(36) USING allergy_id::TEXT;

-- sync_surgery_histories.surgery_history_id: UUID → VARCHAR(36)
ALTER TABLE sync_surgery_histories
    ALTER COLUMN surgery_history_id TYPE VARCHAR(36) USING surgery_history_id::TEXT;


-- =============================================================
-- PATCH 12. 적용 확인
-- =============================================================
-- PK 타입 및 patient_hash 컬럼 전체 확인
SELECT
    column_name,
    data_type,
    character_maximum_length
FROM information_schema.columns
WHERE table_name IN (
    'sync_allergies',
    'sync_surgery_histories',
    'sync_encounters',
    'sync_diagnoses',
    'sync_departments',
    'sync_doctors',
    'sync_patients'
)
ORDER BY table_name, ordinal_position;

SELECT
    conrelid::regclass AS table_name,
    conname,
    pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid IN (
    'sync_allergies'::regclass,
    'sync_surgery_histories'::regclass,
    'sync_encounters'::regclass
)
  AND contype = 'c'
ORDER BY table_name, conname;
