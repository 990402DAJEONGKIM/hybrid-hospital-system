# 온프레미스 PostgreSQL 테이블 구성 가이드

> **대상**: 온프레미스 담당 팀원  
> **관련 파일**: `scripts/onprem-schema-patch.sql`

---

## 1. 전체 테이블 목록

| 테이블 | 상태 | 용도 | AWS 복제 여부 |
|---|---|---|---|
| `patients` | 기존 | 환자 기본정보 (1등급 포함) | 비식별 후 `sync_patients`로 복제 |
| `doctors` | 기존 | 의사 정보 | `sync_doctors`로 복제 |
| `departments` | 기존 | 진료과 정보 | `sync_departments`로 복제 |
| `encounters` | **컬럼 추가** | 진료 방문 이력 | 비식별 후 `sync_encounters`로 복제 |
| `diagnoses` | 기존 | 진단 이력 | 비식별 후 `sync_diagnoses`로 복제 |
| `allergies` | **컬럼 추가** | 알레르기 이력 | 비식별 후 `sync_allergies`로 복제 |
| `clinical_notes` | 기존 | 임상 노트 (1등급 전체) | **복제 금지** |
| `surgery_histories` | **컬럼 추가** | 수술 이력 | 비식별 후 `sync_surgery_histories`로 복제 |
| `wards` | **신규 생성** | 병동 기본정보 | `sync_wards`로 복제 |
| `ward_assignments` | **신규 생성** | 환자 병상 배정 이력 | 미복제 (가용 병상 수 계산용) |
| `users` | 기존 | 온프레미스 웹 계정 | AWS users 테이블과 별도 관리 |
| `sessions` | 기존 | 세션 토큰 | 미복제 |
| `audit_logs` | 기존 | 감사 로그 | 미복제 |

---

## 2. 변경·추가 상세

### 2-1. `encounters` — 컬럼 추가

```sql
ALTER TABLE encounters
    ADD COLUMN IF NOT EXISTS department_code VARCHAR(20) REFERENCES departments(department_code);

ALTER TABLE encounters
    ADD COLUMN IF NOT EXISTS encounter_type VARCHAR(30);
```

| 컬럼 | 타입 | 필요 이유 |
|---|---|---|
| `department_code` | VARCHAR(20) | AWS `sync_encounters`가 진료과별 예약 조회를 위해 필요 |
| `encounter_type` | VARCHAR(30) | 예약 유형과 진료 연결 (`outpatient_new` / `outpatient_return` / `inpatient` / `pre_surgery`) |

**입력 규칙**: 진료 등록 시 반드시 채울 것. NULL이면 AWS 예약 재진 기능이 정상 동작하지 않음.

---

### 2-2. `allergies` — 컬럼 추가

```sql
ALTER TABLE allergies
    ADD COLUMN IF NOT EXISTS allergy_code VARCHAR(50);
```

| 컬럼 | 타입 | 필요 이유 |
|---|---|---|
| `allergy_code` | VARCHAR(50) | AWS에 복제 시 allergy_name(원문)은 1등급이라 전송 불가. 표준 코드만 복제 |

**입력 규칙**: 병원 표준 코드 체계 사용. 예: `ALLERGY_PENICILLIN`, `ALLERGY_SULFA`

---

### 2-3. `surgery_histories` — 컬럼 추가

```sql
ALTER TABLE surgery_histories
    ADD COLUMN IF NOT EXISTS surgery_code VARCHAR(30);
```

| 컬럼 | 타입 | 필요 이유 |
|---|---|---|
| `surgery_code` | VARCHAR(30) | surgery_name(원문) 1등급 — AWS에는 코드만 복제 |

**입력 규칙**: 예: `SURG_APPENDECTOMY`, `SURG_CHOLECYSTECTOMY`

---

### 2-4. `wards` — 신규 테이블

```sql
CREATE TABLE wards (
    ward_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    ward_name  VARCHAR(100) NOT NULL,
    room_type  VARCHAR(20)  NOT NULL CHECK (room_type IN ('single','double','shared')),
    total_beds SMALLINT     NOT NULL CHECK (total_beds > 0),
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);
```

| 컬럼 | 설명 |
|---|---|
| `ward_id` | AWS `sync_wards.ward_id`와 **동일한 UUID** 사용 (pglogical 복제 키) |
| `ward_name` | 병동명. 예: '내과병동', '외과병동' |
| `room_type` | `single`=1인실, `double`=2인실, `shared`=다인실 |
| `total_beds` | 병동 전체 병상 수 (고정값, 물리 침대 수) |

**초기 데이터 예시**:
```sql
INSERT INTO wards (ward_id, ward_name, room_type, total_beds) VALUES
    (gen_random_uuid(), '내과병동 1층', 'shared', 20),
    (gen_random_uuid(), '내과병동 2층', 'double', 10),
    (gen_random_uuid(), '외과병동',     'single',  6);
```

---

### 2-5. `ward_assignments` — 신규 테이블

```sql
CREATE TABLE ward_assignments (
    assignment_id UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id    UUID        NOT NULL REFERENCES patients(patient_id),
    ward_id       UUID        NOT NULL REFERENCES wards(ward_id),
    assigned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    discharged_at TIMESTAMPTZ,
    status        VARCHAR(20) NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','discharged')),
    notes         TEXT
);
```

| 컬럼 | 설명 |
|---|---|
| `patient_id` | patients.patient_id 참조 (이름·주민번호는 이 테이블에 저장 안 함) |
| `status` | `active`=입원 중, `discharged`=퇴원 완료 |
| `discharged_at` | 퇴원 처리 시 현재 시각 기록 |

**가용 병상 계산 쿼리**:
```sql
SELECT
    w.ward_id,
    w.ward_name,
    w.total_beds,
    w.total_beds - COUNT(a.assignment_id) AS available_beds
FROM wards w
LEFT JOIN ward_assignments a
    ON a.ward_id = w.ward_id AND a.status = 'active'
GROUP BY w.ward_id, w.ward_name, w.total_beds;
```
이 값이 다음 단계(STEP 2) 트리거를 통해 AWS `sync_wards.available_beds`로 동기화됨.

---

## 3. AWS 복제 컬럼 매핑표

### patients → sync_patients

| 온프레미스 컬럼 | 처리 방법 | AWS 컬럼 |
|---|---|---|
| `patient_id` | SHA-256 해시 | `patient_id_hash` |
| `birth_date` | 연도만 추출 (EXTRACT YEAR) | `birth_year` |
| `gender_code` | 그대로 | `gender_code` |
| `phone_number` | SHA-256 해시 | `phone_hash` |
| `patient_name` | **복제 금지** (1등급) | — |
| `national_id_encrypted` | **복제 금지** (1등급) | — |

### encounters → sync_encounters

| 온프레미스 컬럼 | 처리 방법 | AWS 컬럼 |
|---|---|---|
| `encounter_id` | 그대로 | `encounter_id` |
| `patient_id` | SHA-256 해시 | `patient_id_hash` |
| `doctor_id` | 그대로 | `doctor_id` |
| `department_code` | 그대로 (신규 추가) | `department_code` |
| `encounter_type` | 그대로 (신규 추가) | `encounter_type` |
| `visit_datetime` | DATE만 추출 | `visit_date` |
| `status_code` | 그대로 | `status_code` |
| `chief_complaint` | **복제 금지** (1등급) | — |

### allergies → sync_allergies

| 온프레미스 컬럼 | 처리 방법 | AWS 컬럼 |
|---|---|---|
| `allergy_id` | 그대로 | `allergy_id` |
| `patient_id` | SHA-256 해시 | `patient_id_hash` |
| `allergy_code` | 그대로 (신규 추가) | `allergy_code` |
| `severity_code` | 그대로 | `severity_code` |
| `allergy_name` | **복제 금지** (1등급) | — |

### surgery_histories → sync_surgery_histories

| 온프레미스 컬럼 | 처리 방법 | AWS 컬럼 |
|---|---|---|
| `surgery_history_id` | 그대로 | `surgery_history_id` |
| `patient_id` | SHA-256 해시 | `patient_id_hash` |
| `surgery_code` | 그대로 (신규 추가) | `surgery_code` |
| `surgery_name` | 그대로 | `surgery_name` |
| `surgery_date` | 그대로 | `surgery_date` |
| `note` | **복제 금지** (1등급) | — |

### wards → sync_wards

| 온프레미스 컬럼 | 처리 방법 | AWS 컬럼 |
|---|---|---|
| `ward_id` | 그대로 | `ward_id` |
| `ward_name` | 그대로 | `ward_name` |
| `room_type` | 그대로 | `room_type` |
| `total_beds` | 그대로 | `total_beds` |
| (계산값) | `total_beds - active_count` | `available_beds` |

---

## 4. 실행 순서

```
1단계  scripts/onprem-schema-patch.sql 실행 (지금 이 파일)
         → 컬럼 추가 + 신규 테이블 생성

2단계  pglogical 복제 트리거 적용 (별도 파일 예정)
         → patients/encounters/allergies 등 변경 시
           SHA-256 해시 처리 후 sync_* 테이블로 UPSERT

3단계  wards 초기 데이터 입력
         → 병동 정보를 wards 테이블에 INSERT
         → AWS sync_wards 로 자동 복제됨

4단계  기존 데이터 백필 (운영 중인 경우)
         → allergy_code, surgery_code 값을
           기존 레코드에 일괄 UPDATE
```

---

## 5. 주의사항

1. **1등급 데이터 복제 금지**: `patient_name`, `national_id_encrypted`, `phone_number`, `chief_complaint`, `diagnosis_text`, `clinical_notes.note_content`, `surgery_histories.note`는 AWS로 전달하지 않는다.
2. **ward_id 고정**: `wards.ward_id` 는 최초 생성 후 변경하지 않는다. AWS `sync_wards`의 외래키로 사용된다.
3. **patient_id는 UUID 그대로 복제하지 않는다**: SHA-256 해시 후 `patient_id_hash`(VARCHAR 64)로만 전달.
4. **available_beds는 온프레미스가 계산**: AWS는 이 값을 읽기 전용으로 표시만 한다.
