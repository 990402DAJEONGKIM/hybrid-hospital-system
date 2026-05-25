# 중소형 병원 하이브리드 보안 아키텍처 — AWS 웹 애플리케이션 인수인계 문서

> **대상**: AI 에이전트 (구현 담당)
> **작성일**: 2026-05-24
> **담당 영역**: AWS (patient portal / staff portal / Aurora RDS)
> **팀 구성**: AWS / GCP / Onpremise 3인 팀 프로젝트

---

## 1. 프로젝트 개요

중소형 병원의 온프레미스 ↔ AWS 하이브리드 보안 아키텍처 구축 프로젝트.
ISMS-P, 개인정보보호법, 의료법 기반 설계 원칙 적용.

**핵심 원칙: Security by Design**
- 민감 의료정보(1등급)는 온프레미스에만 저장
- 비식별화 후 최소 정보만 AWS에 복제 (`sync_*` 테이블)
- AWS는 예약·인증·대외 서비스 담당

---

## 2. 현재 인프라 상태 (구축 완료)

### AWS 리소스
| 리소스 | 이름 | 상태 |
|---|---|---|
| ECS 클러스터 | `aws-ecs-cluster-01` | 운영 중 |
| ECS 서비스 | `patient-service`, `staff-service` | ACTIVE (각 2태스크) |
| Aurora PostgreSQL | `aws-aurora-01` (ap-south-2) | 운영 중 |
| ALB | `aws-patient-alb`, `aws-staff-alb` | 운영 중 |
| WAF | `aws-staff-waf` | staff ALB에 적용 (IP 화이트리스트) |
| ECR | `aws-hospital-nginx-patient`, `aws-hospital-api-patient` 등 | 운영 중 |
| Route53 | `patient.mzclinic.cloud`, `staff.mzclinic.cloud` | 운영 중 |
| Secrets Manager | `hospital/database-url`, `hospital/jwt-secret`, `hospital/api-key` | 운영 중 |
| Bastion Host | `aws-bastion-01` (18.60.109.20) | 운영 중 |

### 네트워크 흐름
```
Browser (HTTPS)
    ↓
Route53 → ALB (HTTPS 443, 인증서 처리)
    ↓
ECS Task (EC2 launch type)
  ├── nginx 컨테이너 (port 80) — 정적 파일 서빙 + API 프록시
  └── FastAPI 컨테이너 (port 8000) — 비즈니스 로직
        ↓
Aurora PostgreSQL (private subnet, port 5432)
```

### Security Groups
| SG | ID | 용도 |
|---|---|---|
| ECS EC2 SG | `sg-06ed51d309fc46ba7` | ECS 인스턴스 |
| Aurora SG | `sg-09f6c3596fb691e55` | Aurora (ECS SG 인바운드 허용됨) |

---

## 3. 기술 스택

| 항목 | 기술 |
|---|---|
| Backend | Python FastAPI (동기, SQLAlchemy ORM) |
| DB Driver | psycopg2-binary |
| 인증 | JWT (httpOnly cookie), bcrypt, python-jose |
| Frontend | Vanilla JS + HTML/CSS (nginx 정적 서빙) |
| IaC | Terraform |
| CI/CD | GitHub Actions → ECR → ECS |
| DB | Aurora PostgreSQL 17.x |

---

## 4. 프로젝트 파일 구조

```
app/
├── patient/                    # 환자 포털 (patient.mzclinic.cloud)
│   ├── backend/
│   │   ├── main.py             # FastAPI 앱 진입점
│   │   ├── core/
│   │   │   ├── database.py     # SQLAlchemy 엔진/세션
│   │   │   ├── security.py     # JWT, 비밀번호 해시, API Key 검증
│   │   │   └── middleware.py   # CORS, TrustedHost
│   │   ├── models/
│   │   │   └── db.py           # SQLAlchemy 모델 (User, Session, Sync*)
│   │   └── routers/
│   │       ├── auth.py         # /auth/* 엔드포인트
│   │       └── portal.py       # /portal/* 엔드포인트
│   └── frontend/               # 정적 파일 (nginx 서빙)
│       ├── login.html
│       ├── index.html
│       └── js/script.js
│
├── staff/                      # 스태프 포털 (staff.mzclinic.cloud)
│   └── (patient와 동일 구조)
│
docker/
├── nginx-patient/              # nginx 설정 + Dockerfile
├── nginx-staff/
└── local-dev-seed.sql          # 로컬 개발용 시드 데이터

terraform/aws/                  # AWS 인프라 Terraform
├── ecs/, rds/, alb/, vpc/ ...
```

---

## 5. 기존 Aurora DB 스키마 (현재 상태)

### 인증 테이블 (AWS 전용)
```sql
users (
    user_id UUID PK,
    email VARCHAR(255) UNIQUE,
    password_hash VARCHAR(255),
    role VARCHAR(10),               -- ⚠️ 변경 예정: role_id FK로 교체
    patient_id_hash VARCHAR(64),    -- SHA-256(온프레미스 patient_id)
    doctor_id UUID,
    is_active BOOLEAN,
    failed_login_cnt SMALLINT,
    locked_until TIMESTAMPTZ,
    last_login_at TIMESTAMPTZ,
    password_changed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)

sessions (
    session_id UUID PK,
    user_id UUID FK -> users,
    refresh_token_hash VARCHAR(64) UNIQUE,
    user_agent TEXT,
    ip_address INET,
    expires_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    is_revoked BOOLEAN
)

audit_logs (
    audit_log_id UUID PK,
    user_id UUID FK -> users,
    patient_id_hash VARCHAR(64),
    action_type VARCHAR(20),
    target_table VARCHAR(50),
    target_id UUID,
    source_ip INET,
    result_code VARCHAR(20),
    event_at TIMESTAMPTZ
)
```

### 온프레미스 → AWS 복제 테이블 (pglogical, 읽기 전용)
```sql
sync_patients       -- patient_id_hash, birth_year, gender_code  (이름/주민번호 없음)
sync_departments    -- department_code, department_name
sync_doctors        -- doctor_id, doctor_name, department_code
sync_encounters     -- encounter_id, patient_id_hash, department_code, doctor_id, visit_date
sync_diagnoses      -- diagnosis_id, encounter_id, diagnosis_code  (진단 원문 없음)
sync_allergies      -- allergy_id, patient_id_hash, allergy_code, severity_code  (원문 없음)
sync_surgery_histories -- surgery_history_id, patient_id_hash, surgery_code  (원문 없음)
```

### 현재 DB 계정
| 이메일 | 역할 | 비밀번호 |
|---|---|---|
| patient@test.com | patient | Test1234! |
| doctor@test.com | doctor | Test1234! |
| admin@test.com | admin | Test1234! |
| testdev@mzclinic.com | patient | 미상 |
| admin@mzclinic.com | admin | 미상 |
| doctor@mzclinic.com | doctor | 미상 |

---

## 6. 기존 구현 완료 목록

### 인증 (app/patient/backend/routers/auth.py 기준)
- [x] `POST /auth/register` — 환자 회원가입 + patient_id_hash 매칭
- [x] `POST /auth/login` — 로그인 + httpOnly JWT 쿠키 발급
- [x] `POST /auth/logout` — 세션 폐기
- [x] `POST /auth/refresh` — Refresh Token Rotation
- [x] `GET  /auth/me` — 현재 사용자 정보 + 비밀번호 만료 여부
- [x] `POST /auth/change-password` — 비밀번호 변경 + 전체 세션 폐기
- [x] 비밀번호 복잡도 검증 (8자 이상, 2종류 이상)
- [x] 로그인 5회 실패 시 계정 잠금 (30분)
- [x] 비밀번호 만료 체크 (90일, /auth/me 응답에 포함)
- [x] API Key 검증 (`X-API-Key` 헤더)

### 인프라 (오늘 작업 완료)
- [x] Aurora SG에 ECS SG 인바운드 허용 (포트 5432)
- [x] ECS Task Role에 SSM Exec 권한 추가
- [x] patient-service enableExecuteCommand 활성화

---

## 7. 신규 구현 목록 (미구현)

### 7-1. DB 신규 테이블 DDL

아래 DDL을 순서대로 Aurora에 적용한다.

```sql
-- STEP 1. 역할/권한 (RBAC) — ISMS-P 2.5.4
-- ============================================================
CREATE TABLE roles (
    role_id     SERIAL       PRIMARY KEY,
    role_code   VARCHAR(30)  UNIQUE NOT NULL,
    role_name   VARCHAR(100) NOT NULL,
    description TEXT,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE permissions (
    permission_id   SERIAL       PRIMARY KEY,
    permission_code VARCHAR(50)  UNIQUE NOT NULL,
    permission_name VARCHAR(100) NOT NULL,
    category        VARCHAR(30),   -- 'appointment','patient','user_mgmt','dashboard'
    description     TEXT
);

CREATE TABLE role_permissions (
    role_id       INT NOT NULL REFERENCES roles(role_id)       ON DELETE CASCADE,
    permission_id INT NOT NULL REFERENCES permissions(permission_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE menus (
    menu_id    SERIAL       PRIMARY KEY,
    menu_code  VARCHAR(50)  UNIQUE NOT NULL,
    menu_name  VARCHAR(100) NOT NULL,
    menu_url   VARCHAR(200),
    parent_id  INT          REFERENCES menus(menu_id),
    sort_order INT          NOT NULL DEFAULT 0,
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE role_menus (
    role_id INT NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    menu_id INT NOT NULL REFERENCES menus(menu_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, menu_id)
);


-- ============================================================
-- STEP 2. 인증 강화 — ISMS-P 2.5.1 / 2.5.3 / 2.9.1
-- ============================================================
CREATE TABLE user_mfa (
    mfa_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    mfa_type    VARCHAR(10) NOT NULL DEFAULT 'totp',
    secret      VARCHAR(64) NOT NULL,      -- 암호화 저장 권장 (KMS)
    is_active   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified_at TIMESTAMPTZ
);

CREATE TABLE password_policy (
    policy_id         SERIAL  PRIMARY KEY,
    min_length        INT     NOT NULL DEFAULT 8,
    require_uppercase BOOLEAN NOT NULL DEFAULT TRUE,
    require_lowercase BOOLEAN NOT NULL DEFAULT TRUE,
    require_digit     BOOLEAN NOT NULL DEFAULT TRUE,
    require_special   BOOLEAN NOT NULL DEFAULT TRUE,
    expire_days       INT     NOT NULL DEFAULT 90,
    max_failed_logins INT     NOT NULL DEFAULT 5,
    lockout_minutes   INT     NOT NULL DEFAULT 30,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by        UUID    REFERENCES users(user_id)
);

CREATE TABLE login_history (
    history_id  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        REFERENCES users(user_id) ON DELETE SET NULL,
    email       VARCHAR(255),
    result      VARCHAR(10) NOT NULL,   -- 'success', 'fail', 'locked'
    ip_address  INET,
    user_agent  TEXT,
    event_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);


CREATE INDEX idx_login_history_user    ON login_history(user_id);
CREATE INDEX idx_login_history_event   ON login_history(event_at);
SELECT * FROM login_history;




-- ============================================================
-- STEP 3. users 테이블 수정 — role VARCHAR → role_id FK
-- ============================================================
-- 3-1. role_id 컬럼 추가
ALTER TABLE users ADD COLUMN role_id INT REFERENCES roles(role_id);


-- roles
INSERT INTO roles (role_code, role_name, description) VALUES
  ('patient', '환자',      '웹 예약 포털 사용자'),
  ('doctor',  '의사',      '진료 담당 의료진'),
  ('nurse',   '원무과',    '예약 접수 및 관리 담당'),
  ('admin',   'IT관리자',  '시스템 전체 관리');



-- 3-2. 기존 데이터 마이그레이션 (roles 시드 삽입 후 실행)
UPDATE users u SET role_id = r.role_id
FROM roles r WHERE r.role_code = u.role;

select * from users


-- 3-3. NOT NULL 설정 + 기존 role 컬럼 제거
ALTER TABLE users ALTER COLUMN role_id SET NOT NULL;
ALTER TABLE users DROP COLUMN role;

-- 3-4. 비밀번호 만료일 컬럼 추가
--1단계: 컬럼 추가
ALTER TABLE users ADD COLUMN password_expires_at TIMESTAMPTZ;

--2단계: 함수 생성
CREATE OR REPLACE FUNCTION update_password_expires_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.password_expires_at := NEW.password_changed_at + INTERVAL '90 days';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

--3단계: 트리거 생성
CREATE TRIGGER trg_password_expires_at
BEFORE INSERT OR UPDATE OF password_changed_at ON users
FOR EACH ROW
EXECUTE FUNCTION update_password_expires_at();


--4단계: 기존 데이터 채우기
UPDATE users SET password_expires_at = password_changed_at + INTERVAL '90 days';



--다 실행한 후 잘 됐는지 확인:
SELECT user_id, password_changed_at, password_expires_at
FROM users
LIMIT 5;




-- ============================================================
-- STEP 4. 예약 시스템 — SFR-001
-- ============================================================

CREATE TABLE appointment_types (
    type_id                 SERIAL       PRIMARY KEY,
    type_code               VARCHAR(30)  UNIQUE NOT NULL,
    -- 'outpatient_new'    초진 외래
    -- 'outpatient_return' 재진 외래
    -- 'inpatient'         입원
    -- 'pre_surgery'       수술 전
    type_name               VARCHAR(100) NOT NULL,
    requires_previous_visit BOOLEAN      NOT NULL DEFAULT FALSE,
    description             TEXT,
    is_active               BOOLEAN      NOT NULL DEFAULT TRUE,
    sort_order              INT          NOT NULL DEFAULT 0
);

CREATE TABLE appointment_statuses (
    status_id   SERIAL      PRIMARY KEY,
    status_code VARCHAR(20) UNIQUE NOT NULL,
    -- 'pending'    대기 중
    -- 'confirmed'  확정
    -- 'cancelled'  취소
    -- 'completed'  완료
    -- 'no_show'    노쇼
    status_name VARCHAR(50) NOT NULL,
    is_terminal BOOLEAN     NOT NULL DEFAULT FALSE,
    sort_order  INT         NOT NULL DEFAULT 0
);

CREATE TABLE appointments (
    appointment_id   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_user_id  UUID        NOT NULL REFERENCES users(user_id),
    patient_id_hash  VARCHAR(64) REFERENCES sync_patients(patient_id_hash),
    type_id          INT         NOT NULL REFERENCES appointment_types(type_id),
    status_id        INT         NOT NULL REFERENCES appointment_statuses(status_id),
    department_code  VARCHAR(20) REFERENCES sync_departments(department_code),
    doctor_id        VARCHAR(36) REFERENCES sync_doctors(doctor_id),    -- VARCHAR(36)
    ward_id          UUID        REFERENCES sync_wards(ward_id),        -- UUID
    room_type_pref   VARCHAR(20),
    has_chronic_condition BOOLEAN,
    appointment_date DATE        NOT NULL,
    appointment_time TIME        NOT NULL,
    confirmed_at     TIMESTAMPTZ,
    confirmed_by     UUID        REFERENCES users(user_id),
    cancelled_at     TIMESTAMPTZ,
    cancelled_by     UUID        REFERENCES users(user_id),
    cancel_reason    VARCHAR(200),
    notes            TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);



CREATE INDEX idx_appointments_patient  ON appointments(patient_user_id);
CREATE INDEX idx_appointments_doctor   ON appointments(doctor_id);
CREATE INDEX idx_appointments_date     ON appointments(appointment_date);
CREATE INDEX idx_appointments_status   ON appointments(status_id);

CREATE TABLE appointment_history (
    history_id       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id   UUID        NOT NULL REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    changed_by       UUID        REFERENCES users(user_id),
    prev_status_id   INT         REFERENCES appointment_statuses(status_id),
    new_status_id    INT         REFERENCES appointment_statuses(status_id),
    prev_date        DATE,
    new_date         DATE,
    prev_time        TIME,
    new_time         TIME,
    change_reason    VARCHAR(200),
    changed_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);




-- ============================================================
-- STEP 5. 병상 (온프레미스 sync) — SFR-001 입원 예약
-- ============================================================

CREATE TABLE sync_wards (
    ward_id        UUID         PRIMARY KEY,
    ward_name      VARCHAR(100),               -- '내과병동', '외과병동'
    room_type      VARCHAR(20),                -- 'shared','double','single'
    total_beds     SMALLINT,
    available_beds SMALLINT,                   -- 가용 병상 수 (숫자만, 개별 배정 정보 없음)
    synced_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);


-- ============================================================
-- STEP 6. 알림 — SFR-001 (AWS SES)
-- ============================================================

CREATE TABLE notification_types (
    notification_type_id SERIAL       PRIMARY KEY,
    type_code            VARCHAR(30)  UNIQUE NOT NULL,
    -- 'appointment_confirmed' 예약 확정
    -- 'appointment_cancelled' 예약 취소
    -- 'appointment_changed'   예약 변경
    -- 'appointment_reminder'  예약 알림
    -- 'account_locked'        계정 잠금 (관리자 수신)
    -- 'password_expiring'     비밀번호 만료 예고
    type_name            VARCHAR(100) NOT NULL,
    email_subject_tmpl   TEXT,
    email_body_tmpl      TEXT,
    is_active            BOOLEAN      NOT NULL DEFAULT TRUE
);


CREATE TABLE notifications (
    notification_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              UUID        NOT NULL REFERENCES users(user_id),
    notification_type_id INT         REFERENCES notification_types(notification_type_id),
    appointment_id       UUID        REFERENCES appointments(appointment_id),
    channel              VARCHAR(20) NOT NULL DEFAULT 'email',
    status               VARCHAR(20) NOT NULL DEFAULT 'pending',
    -- 'pending', 'sent', 'failed'
    sent_at              TIMESTAMPTZ,
    error_message        TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_notifications_user ON notifications(user_id);
CREATE INDEX idx_notifications_appt ON notifications(appointment_id);



-- ============================================================
-- STEP 7. 시드 데이터
-- ============================================================

-- permissions
INSERT INTO permissions (permission_code, permission_name, category) VALUES
  ('VIEW_OWN_APPOINTMENTS',  '본인 예약 조회',     'appointment'),
  ('CREATE_APPOINTMENT',     '예약 생성',          'appointment'),
  ('CANCEL_OWN_APPOINTMENT', '본인 예약 취소',     'appointment'),
  ('CHANGE_OWN_APPOINTMENT', '본인 예약 변경',     'appointment'),
  ('VIEW_ALL_APPOINTMENTS',  '전체 예약 조회',     'appointment'),
  ('MANAGE_APPOINTMENTS',    '예약 관리',          'appointment'),
  ('VIEW_OWN_RECORDS',       '본인 진료기록 조회', 'patient'),
  ('VIEW_PATIENT_RECORDS',   '환자 진료기록 조회', 'patient'),
  ('MANAGE_USERS',           '계정 관리',          'user_mgmt'),
  ('MANAGE_ROLES',           '역할/권한 관리',     'user_mgmt'),
  ('VIEW_DASHBOARD',         '대시보드 조회',      'dashboard'),
  ('VIEW_WARD_STATUS',       '병동 현황 조회',     'dashboard');

-- role_permissions
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles r, permissions p WHERE
  (r.role_code='patient' AND p.permission_code IN (
    'VIEW_OWN_APPOINTMENTS','CREATE_APPOINTMENT',
    'CANCEL_OWN_APPOINTMENT','CHANGE_OWN_APPOINTMENT','VIEW_OWN_RECORDS'))
  OR (r.role_code='doctor' AND p.permission_code IN (
    'VIEW_ALL_APPOINTMENTS','VIEW_PATIENT_RECORDS','VIEW_DASHBOARD'))
  OR (r.role_code='nurse' AND p.permission_code IN (
    'VIEW_ALL_APPOINTMENTS','MANAGE_APPOINTMENTS',
    'VIEW_PATIENT_RECORDS','VIEW_DASHBOARD','VIEW_WARD_STATUS'))
  OR (r.role_code='admin' AND p.permission_code IN (
    'VIEW_ALL_APPOINTMENTS','MANAGE_APPOINTMENTS','VIEW_PATIENT_RECORDS',
    'MANAGE_USERS','MANAGE_ROLES','VIEW_DASHBOARD','VIEW_WARD_STATUS'));

-- appointment_types
INSERT INTO appointment_types (type_code, type_name, requires_previous_visit, sort_order) VALUES
  ('outpatient_new',    '초진 외래', FALSE, 1),
  ('outpatient_return', '재진 외래', TRUE,  2),
  ('inpatient',         '입원',      FALSE, 3),
  ('pre_surgery',       '수술 전',   TRUE,  4);

-- appointment_statuses
INSERT INTO appointment_statuses (status_code, status_name, is_terminal, sort_order) VALUES
  ('pending',   '대기 중', FALSE, 1),
  ('confirmed', '확정',    FALSE, 2),
  ('cancelled', '취소',    TRUE,  3),
  ('completed', '완료',    TRUE,  4),
  ('no_show',   '노쇼',    TRUE,  5);

-- notification_types
INSERT INTO notification_types (type_code, type_name) VALUES
  ('appointment_confirmed', '예약 확정'),
  ('appointment_cancelled', '예약 취소'),
  ('appointment_changed',   '예약 변경'),
  ('appointment_reminder',  '예약 알림'),
  ('account_locked',        '계정 잠금 알림'),
  ('password_expiring',     '비밀번호 만료 예고');

-- password_policy (기본값)
INSERT INTO password_policy
  (min_length, require_uppercase, require_lowercase, require_digit,
   require_special, expire_days, max_failed_logins, lockout_minutes)
VALUES (8, TRUE, TRUE, TRUE, TRUE, 90, 5, 30);
```

---

---

## 8. Backend 구현 목록

### 8-1. 공통 변경사항

| 파일 | 변경 내용 | ISMS-P |
|---|---|---|
| `models/db.py` | 신규 테이블 SQLAlchemy 모델 추가 (Role, Permission, Appointment 등) | - |
| `core/security.py` | `has_permission(user_id, permission_code, db)` 함수 추가 | 2.5.4 |
| `core/security.py` | JWT payload에 `role_id` 포함 (`role` 문자열 → `role_id` 정수) | 2.5.4 |
| `routers/auth.py` | role → role_id 기반으로 로그인 로직 수정 | 2.5.2 |
| `routers/auth.py` | 모든 엔드포인트에 `audit_logs` 기록 추가 | 2.9.1 |
| `routers/auth.py` | 계정 잠금 발생 시 admin 계정에 SES 알림 발송 | 2.5.1 |
| `routers/auth.py` | 비밀번호 정책을 하드코딩 → `password_policy` 테이블에서 동적 로드 | 2.5.3 |
| `routers/auth.py` | 로그인 이력 `login_history` 테이블 기록 | 2.9.1 |

### 8-2. 인증 강화 신규 엔드포인트

| 엔드포인트 | 설명 | 적용 역할 | ISMS-P |
|---|---|---|---|
| `POST /auth/mfa/setup` | TOTP QR 코드 발급 | doctor/nurse/admin | 2.5.3 |
| `POST /auth/mfa/verify` | TOTP 6자리 인증 | doctor/nurse/admin | 2.5.3 |
| `GET  /auth/me/permissions` | 본인 권한 목록 반환 | 전체 | 2.5.4 |
| `GET  /auth/me/menus` | 본인 접근 가능 메뉴 목록 반환 | 전체 | 2.5.4 |

### 8-3. 예약 API (환자용)

> **비식별화 규칙**: Pydantic 스키마에서 허용 필드만 정의하여 자동 차단

| 엔드포인트 | 설명 | 허용 입력 필드만 |
|---|---|---|
| `GET  /appointments/types` | 예약 유형 목록 | - |
| `GET  /appointments/available-slots` | 가용 날짜/시간 조회 | `department_code`, `date` |
| `GET  /wards/availability` | 병동별 가용 병상 수 | - |
| `POST /appointments/outpatient-new` | 초진 예약 | `department_code`, `date`, `time` |
| `POST /appointments/outpatient-return` | 재진 예약 | `patient_id_hash`, `department_code`, `doctor_id`, `date`, `time` |
| `POST /appointments/inpatient` | 입원 예약 | `ward_id`, `room_type_pref`, `has_chronic_condition`(bool) |
| `POST /appointments/pre-surgery` | 수술 전 예약 | `allergy_code[]`, `surgery_code[]`, `pre_exam_date` |
| `GET  /appointments` | 본인 예약 목록 | - |
| `GET  /appointments/{id}` | 예약 상세 | - |
| `GET  /appointments/{id}/history` | 변경 이력 | - |
| `PATCH /appointments/{id}` | 예약 변경 (비밀번호 재확인) | `date`, `time`, `password` |
| `DELETE /appointments/{id}` | 예약 취소 (비밀번호 재확인) | `password`, `cancel_reason` |

### 8-4. 예약 API (스태프용)

| 엔드포인트 | 역할 | 설명 |
|---|---|---|
| `GET  /staff/appointments` | nurse/doctor/admin | 전체 예약 조회 (날짜/상태 필터) |
| `POST /staff/appointments` | nurse | 수동 예약 등록 |
| `PATCH /staff/appointments/{id}/confirm` | nurse | 예약 확정 처리 |
| `PATCH /staff/appointments/{id}/complete` | nurse/doctor | 진료 완료 처리 |
| `PATCH /staff/appointments/{id}/no-show` | nurse | 노쇼 처리 |
| `GET  /staff/wards` | nurse/admin | 병동 현황 조회 |

### 8-5. 관리자 API

| 엔드포인트 | 설명 | ISMS-P |
|---|---|---|
| `GET  /admin/users` | 계정 목록 | 2.5.1 |
| `POST /admin/users` | 계정 생성 | 2.5.1 |
| `PATCH /admin/users/{id}` | 계정 수정 | 2.5.1 |
| `PATCH /admin/users/{id}/lock` | 계정 잠금 | 2.5.1 |
| `DELETE /admin/users/{id}` | 계정 삭제 | 2.5.1 |
| `GET  /admin/roles` | 역할 목록 | 2.5.4 |
| `POST /admin/roles` | 역할 추가 | 2.5.4 |
| `PATCH /admin/roles/{id}/permissions` | 역할 권한 수정 | 2.5.4 |
| `PATCH /admin/roles/{id}/menus` | 역할 메뉴 수정 | 2.5.4 |
| `GET  /admin/password-policy` | 비밀번호 정책 조회 | 2.5.3 |
| `PATCH /admin/password-policy` | 비밀번호 정책 수정 | 2.5.3 |
| `GET  /admin/login-history` | 로그인 이력 조회 | 2.9.1 |

### 8-6. 알림 (AWS SES)

| 이벤트 | 수신자 | 발송 시점 |
|---|---|---|
| 예약 제출 완료 | 환자 | 예약 생성 직후 |
| 예약 확정 | 환자 | 원무 확정 처리 시 |
| 예약 변경 | 환자 | 변경 완료 시 |
| 예약 취소 | 환자 | 취소 완료 시 |
| 계정 잠금 발생 | admin | 5회 실패 잠금 시 |
| 비밀번호 만료 7일 전 | 해당 사용자 | 배치 또는 로그인 시 체크 |

### 8-7. ISMS-P 감사 로그 (모든 API 공통)

`audit_logs` 테이블에 아래 이벤트 기록:

| 이벤트 | action_type |
|---|---|
| 로그인 / 로그아웃 | `LOGIN` / `LOGOUT` |
| 로그인 실패 / 계정 잠금 | `LOGIN_FAIL` / `ACCOUNT_LOCKED` |
| 예약 생성 / 변경 / 취소 | `APPT_CREATE` / `APPT_UPDATE` / `APPT_CANCEL` |
| 환자 진료기록 조회 | `RECORD_VIEW` |
| 계정 생성 / 수정 / 잠금 / 삭제 | `USER_CREATE` / `USER_UPDATE` / `USER_LOCK` / `USER_DELETE` |
| 권한 / 역할 변경 | `ROLE_UPDATE` / `PERM_UPDATE` |
| 비밀번호 변경 | `PASSWORD_CHANGE` |

---

## 9. Frontend 구현 목록

### 9-1. 환자 포털 (patient.mzclinic.cloud)

| 페이지 | 파일 경로 | 설명 |
|---|---|---|
| 로그인 | `login.html` (기존) | 기존 유지 |
| 회원가입 | `register.html` (기존) | 기존 유지 |
| 비밀번호 변경 | `change-password.html` | 만료 시 강제 리다이렉트 |
| 예약 유형 선택 | `appointment.html` | 초진/재진/입원/수술 전 선택 |
| 초진 예약 | `appointment-new.html` | 진료과 → 날짜/시간 → 확인 (3단계) |
| 재진 예약 | `appointment-return.html` | 최근 담당의/진료과 자동 표시 |
| 입원 예약 | `appointment-inpatient.html` | 병동 선택 + 기저질환 유무(있음/없음) |
| 수술 전 예약 | `appointment-surgery.html` | 알레르기 코드 / 수술 이력 코드 목록 (원문 없음) |
| 예약 내역 | `my-appointments.html` | 상태별 필터, 변경 이력 포함 |
| 예약 변경 | `appointment-edit.html` | 비밀번호 재확인 후 처리 |
| 진료기록 | `my-records.html` | sync_encounters, sync_diagnoses 기반 |
| 세션 만료 팝업 | (공통 JS) | 만료 5분 전 경고, 연장 버튼 |

### 9-2. 스태프 포털 (staff.mzclinic.cloud)

**공통**
| 페이지 | 설명 |
|---|---|
| 로그인 |
| 역할별 메뉴 자동 렌더링 | `GET /auth/me/menus` 응답 기반 |

**원무과 (nurse)**
| 페이지 | 설명 |
|---|---|
| 예약 현황 대시보드 | 날짜별/상태별 예약 목록 + 통계 |
| 예약 상세 | 확정 / 취소 / 노쇼 처리 버튼 |
| 수동 예약 등록 | 방문 환자 직접 등록 |
| 병동 현황 | 병동별 가용 병상 수 |

**의사 (doctor)**
| 페이지 | 설명 |
|---|---|
| 오늘 진료 목록 | 확정된 예약, 시간순 정렬 |
| 환자 상세 | 예약 정보 + 진료기록/진단/알레르기 (코드 기반) |

**관리자 (admin)**
| 페이지 | 설명 | ISMS-P |
|---|---|---|
| 사용자 계정 관리 | 생성/수정/잠금/삭제 | 2.5.1 |
| 역할/권한 관리 | 역할 추가, 권한 할당, 메뉴 할당 | 2.5.4 |
| 비밀번호 정책 설정 | 최소 길이, 복잡도, 만료 주기 | 2.5.3 |
| 로그인 이력 조회 | 성공/실패/잠금, IP, 시각 | 2.9.1 |

---

## 10. 비식별화 규칙 (SFR-004) — 코드 레벨 강제

FastAPI Pydantic Request 스키마에서 허용 필드만 정의 → 나머지 자동 차단

| 예약 유형 | 허용 필드 | 절대 금지 필드 |
|---|---|---|
| 초진 | `department_code`, `date`, `time` | EMR 전체 |
| 재진 | `patient_id_hash`, `department_code`, `doctor_id`, `date`, `time` | 이름, 주민번호, 진단 원문 |
| 입원 | `ward_id`, `room_type_pref`, `has_chronic_condition`(bool) | 기저질환명 원문 |
| 수술 전 | `allergy_code[]`, `surgery_code[]`, `pre_exam_date` | 알레르기명/수술명/진단 원문 |
| 환자 조회 | `patient_id_hash`, `birth_year`, `gender_code` | 이름, 연락처, 주민번호 |

---

## 11. 작업 순서

```
1단계  전체 DDL Aurora 적용
       (STEP 1~7 순서대로 실행, roles 시드 먼저 삽입 후 users 마이그레이션)

2단계  Backend 공통 변경
       - SQLAlchemy 모델 추가
       - has_permission() 구현
       - role_id 기반 로그인 수정
       - audit_logs 공통 기록

3단계  인증 강화
       - login_history 기록
       - password_policy 동적 로드
       - 계정 잠금 → admin SES 알림
       - MFA (TOTP) 구현
       - 세션 만료 5분 전 경고

4단계  예약 Backend API
       초진 → 재진 → 입원 → 수술 전 순서

5단계  환자 포털 예약 UI

6단계  스태프 포털
       원무 대시보드 → 의사 화면 → 관리자 화면

7단계  SES 알림 연동

8단계  전체 감사 로그 검증
```

---

## 12. 주의사항

1. **1등급 데이터 절대 저장 금지**: 환자 이름, 주민번호, 원문 진단명, 연락처는 AWS에 저장하지 않는다.
2. **sync_* 테이블은 읽기 전용**: pglogical로 온프레미스에서 복제되므로 AWS에서 직접 INSERT/UPDATE 금지.
3. **role_id 마이그레이션**: `users` 테이블의 `role` 컬럼 제거 전 반드시 roles 시드 데이터 삽입 후 마이그레이션 UPDATE 실행.
4. **MFA 강제 적용 대상**: doctor, nurse, admin 역할 계정은 최초 로그인 시 MFA 등록 화면으로 강제 이동.
5. **본인 확인 (예약 변경/취소)**: 비밀번호 재확인 로직은 기존 `/auth/change-password`의 `verify_password()` 패턴 재사용.
6. **병상 데이터**: `sync_wards`는 온프레미스에서 pglogical로 동기화. AWS에서 직접 수정 불가. 병상 수만 노출, 개별 환자 배정 정보 없음.
7. **SES 발신 도메인**: AWS SES에서 `mzclinic.cloud` 도메인 인증 필요 (인프라 팀 협의).
