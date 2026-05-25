-- =============================================================
-- 온프레미스 PostgreSQL — 스키마 보완 패치
--
-- 목적: AWS Aurora pglogical 단방향 복제(onprem → AWS)에 필요한
--       컬럼·테이블을 온프레미스 DB에 추가한다.
--
-- 실행 방법:
--   psql -U <온프레미스_DB_계정> -d <DB명> -f onprem-schema-patch.sql
--
-- 멱등성(idempotent): IF NOT EXISTS / IF EXISTS 조건 사용,
--   이미 적용된 환경에서 재실행해도 오류 없음.
--
-- 적용 순서:
--   STEP 1. encounters 컬럼 추가 (department_code, encounter_type)
--   STEP 2. allergies 컬럼 추가  (allergy_code)
--   STEP 3. surgery_histories 컬럼 추가 (surgery_code)
--   STEP 4. wards 테이블 신규 생성
--   STEP 5. ward_assignments 테이블 신규 생성
--   STEP 6. 인덱스
--   STEP 7. 적용 확인 쿼리
-- =============================================================


-- =============================================================
-- STEP 1. encounters — department_code, encounter_type 추가
--
-- [WHY]
--   AWS sync_encounters 에는 department_code + encounter_type 컬럼이
--   필요하다.  현재 온프레미스 encounters 에는 두 컬럼이 없어
--   pglogical 복제 시 해당 필드가 NULL로 채워지거나 복제가 거부된다.
--
--   · department_code : 어느 진료과에서 진료가 이루어졌는지
--                       (sync_encounters.department_code 와 1:1 매핑)
--   · encounter_type  : 'outpatient_new' | 'outpatient_return' |
--                       'inpatient' | 'pre_surgery' 등
--                       예약 유형과 진료 유형을 연결하는 키 값
-- =============================================================

ALTER TABLE encounters
    ADD COLUMN IF NOT EXISTS department_code VARCHAR(20)
        REFERENCES departments(department_code);

ALTER TABLE encounters
    ADD COLUMN IF NOT EXISTS encounter_type VARCHAR(30);

COMMENT ON COLUMN encounters.department_code IS '진료과 코드 — departments.department_code 참조 (AWS sync_encounters 복제 대상)';
COMMENT ON COLUMN encounters.encounter_type  IS '진료 유형 (outpatient_new / outpatient_return / inpatient / pre_surgery) — AWS sync_encounters 복제 대상';


-- =============================================================
-- STEP 2. patients — phone_hash 추가
--
-- [WHY]
--   AWS sync_patients 에는 phone_hash(SHA256) 만 복제된다.
--   phone_number 원문이 AWS로 이동하면 ISMS-P 1등급 위반이므로
--   온프레미스에서 해시를 미리 계산해 저장하고, pglogical은
--   phone_hash 만 복제한다.
--   phone_number 는 pglogical 복제 대상에서 반드시 제외할 것.
-- =============================================================

ALTER TABLE patients
    ADD COLUMN IF NOT EXISTS phone_hash VARCHAR(64);

COMMENT ON COLUMN patients.phone_hash IS 'SHA256(phone_number) — AWS sync_patients 복제 대상. phone_number 원문은 복제 금지(1등급)';

-- 기존 데이터 phone_hash 채우기 (pgcrypto 필요)
UPDATE patients
SET phone_hash = encode(digest(phone_number, 'sha256'), 'hex')
WHERE phone_number IS NOT NULL
  AND phone_hash IS NULL;

-- 신규 환자 INSERT / UPDATE 시 자동 계산 트리거
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

CREATE INDEX IF NOT EXISTS idx_patients_phone_hash ON patients(phone_hash);


-- =============================================================
-- STEP 4. allergies — allergy_code 추가
--
-- [WHY]
--   AWS sync_allergies 는 allergy_name(원문, 1등급) 대신
--   allergy_code(표준코드, 비식별) 만 저장한다.
--   현재 온프레미스 allergies 에 allergy_code 컬럼이 없으면
--   복제 시 항상 NULL이 들어가 AWS 측 수술 전 예약
--   (/appointments/pre-surgery) 의 알레르기 코드 목록이 비어 있게 된다.
--
--   예) 'ALLERGY_PENICILLIN', 'ALLERGY_SULFA', 'ALLERGY_LATEX' 등
--       병원 표준 코드 체계를 사용할 것.
-- =============================================================

ALTER TABLE allergies
    ADD COLUMN IF NOT EXISTS allergy_code VARCHAR(50);

COMMENT ON COLUMN allergies.allergy_code IS '알레르기 표준코드 — AWS sync_allergies 복제 대상 (allergy_name 원문은 복제 금지, 1등급)';


-- =============================================================
-- STEP 5. surgery_histories — surgery_code 추가
--
-- [WHY]
--   AWS sync_surgery_histories 는 surgery_name(원문, 1등급) 대신
--   surgery_code(표준코드) 만 저장한다.
--   surgery_code 가 없으면 수술 전 예약에서 수술 이력 코드 목록이
--   조회되지 않는다.
--
--   예) 'SURG_APPENDECTOMY', 'SURG_CHOLECYSTECTOMY' 등
-- =============================================================

ALTER TABLE surgery_histories
    ADD COLUMN IF NOT EXISTS surgery_code VARCHAR(30);

COMMENT ON COLUMN surgery_histories.surgery_code IS '수술 표준코드 — AWS sync_surgery_histories 복제 대상 (surgery_name 원문은 복제 금지, 1등급)';


-- =============================================================
-- STEP 6. wards 테이블 신규 생성
--
-- [WHY]
--   AWS sync_wards 의 원본 데이터 소스.
--   병동 기본 정보(이름, 유형, 전체 병상 수)를 관리한다.
--   available_beds 는 ward_assignments 를 기반으로 트리거/배치가
--   계산하여 동기화 시 전달한다 (STEP 2 에서 구현).
--
--   room_type 허용값: 'single'(1인실), 'double'(2인실), 'shared'(다인실)
-- =============================================================

CREATE TABLE IF NOT EXISTS wards (
    ward_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    ward_name  VARCHAR(100) NOT NULL,
    room_type  VARCHAR(20)  NOT NULL CHECK (room_type IN ('single','double','shared')),
    total_beds SMALLINT     NOT NULL CHECK (total_beds > 0),
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE  wards            IS '병동 기본 정보 — AWS sync_wards 복제 원본';
COMMENT ON COLUMN wards.ward_id    IS 'AWS sync_wards.ward_id 와 동일 UUID 사용';
COMMENT ON COLUMN wards.room_type  IS 'single=1인실 / double=2인실 / shared=다인실';
COMMENT ON COLUMN wards.total_beds IS '병동 전체 병상 수 (고정값)';


-- =============================================================
-- STEP 7. ward_assignments 테이블 신규 생성
--
-- [WHY]
--   개별 환자의 병상 배정 이력을 기록한다.
--   이 테이블의 active 레코드 수를 집계하면 가용 병상을 계산할 수 있다:
--     available_beds = total_beds
--                      - COUNT(*) WHERE ward_id = ? AND status = 'active'
--
--   이 값이 pglogical 복제 시 AWS sync_wards.available_beds 로 전달된다.
--   (STEP 2 트리거에서 wards.available_beds 컬럼을 자동 갱신 예정)
--
--   status 허용값: 'active'(입원 중), 'discharged'(퇴원 완료)
--
--   주의: 이 테이블은 환자 실명(patient_name 등 1등급)을
--         절대 참조·저장하지 않는다. patient_id(UUID) 만 사용.
-- =============================================================

CREATE TABLE IF NOT EXISTS ward_assignments (
    assignment_id UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    UUID        NOT NULL REFERENCES patients(patient_id),
    ward_id       UUID        NOT NULL REFERENCES wards(ward_id),
    assigned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    discharged_at TIMESTAMPTZ,
    status        VARCHAR(20) NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','discharged')),
    notes         TEXT
);

COMMENT ON TABLE  ward_assignments              IS '환자 병상 배정 이력 — available_beds 계산 원본 (1등급 PII 저장 금지)';
COMMENT ON COLUMN ward_assignments.patient_id   IS 'patients.patient_id 참조 (이름·주민번호는 저장하지 않음)';
COMMENT ON COLUMN ward_assignments.status       IS 'active=입원중 / discharged=퇴원';
COMMENT ON COLUMN ward_assignments.discharged_at IS '퇴원 시각 — status=discharged 로 변경할 때 함께 기록';


-- =============================================================
-- STEP 8. 인덱스
-- =============================================================

-- encounters
CREATE INDEX IF NOT EXISTS idx_enc_dept_code ON encounters(department_code);
CREATE INDEX IF NOT EXISTS idx_enc_type      ON encounters(encounter_type);

-- allergies
CREATE INDEX IF NOT EXISTS idx_allergy_code  ON allergies(allergy_code);

-- surgery_histories
CREATE INDEX IF NOT EXISTS idx_surg_code     ON surgery_histories(surgery_code);

-- ward_assignments
CREATE INDEX IF NOT EXISTS idx_ward_asgn_patient ON ward_assignments(patient_id);
CREATE INDEX IF NOT EXISTS idx_ward_asgn_ward    ON ward_assignments(ward_id);
CREATE INDEX IF NOT EXISTS idx_ward_asgn_status  ON ward_assignments(status);


-- =============================================================
-- STEP 9. 적용 확인
-- =============================================================

-- patients phone_hash 컬럼 및 데이터 확인
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'patients'
  AND column_name = 'phone_hash';

SELECT count(*) AS patients_with_hash
FROM patients WHERE phone_hash IS NOT NULL;

-- encounters 컬럼 확인
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'encounters'
  AND column_name IN ('department_code','encounter_type')
ORDER BY column_name;

-- allergies 컬럼 확인
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'allergies'
  AND column_name = 'allergy_code';

-- surgery_histories 컬럼 확인
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'surgery_histories'
  AND column_name = 'surgery_code';

-- 신규 테이블 존재 확인
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('wards','ward_assignments')
ORDER BY tablename;
