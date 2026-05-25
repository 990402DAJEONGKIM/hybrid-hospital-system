# DB 스키마 가이드

> 대상 독자: 온프레미스 담당 팀원  
> 작성 기준: 2026-05-25

---

## 1. 온프레미스 DB 변경 내역

기존 온프레미스 DB에 아래 항목이 추가되었습니다.  
**적용 파일**: `scripts/onprem-schema-patch.sql` → `scripts/onprem-webapp-init.sql` 순서로 실행

### 1-1. 기존 테이블에 컬럼 추가

| 테이블 | 추가 컬럼 | 이유 |
|--------|-----------|------|
| `patients` | `phone_hash VARCHAR(64)` | phone_number의 SHA256 해시 — AWS로는 해시만 복제, 원문은 복제 금지 |
| `encounters` | `department_code VARCHAR(20)` | AWS pglogical 복제 시 진료과 정보 전달 |
| `encounters` | `encounter_type VARCHAR(30)` | AWS 예약 유형과 연결 (outpatient_new 등) |
| `allergies` | `allergy_code VARCHAR(50)` | 원문(1등급) 대신 표준코드만 AWS로 복제 |
| `surgery_histories` | `surgery_code VARCHAR(30)` | 원문(1등급) 대신 표준코드만 AWS로 복제 |
| `users` | `password_changed_at TIMESTAMPTZ` | 비밀번호 만료 정책 (ISMS-P 2.5.3) |
| `users` | `updated_at TIMESTAMPTZ` | 계정 변경 이력 추적 |
| `sessions` | `user_agent TEXT` | 로그인 기기 식별 |
| `sessions` | `last_used_at TIMESTAMPTZ` | 세션 만료 정책 |
| `audit_logs` | `source_ip INET` | 접근 IP 기록 (ISMS-P 2.9.1) |
| `audit_logs` | `result_code VARCHAR(20)` | 작업 성공/실패 코드 |
| `audit_logs` | `patient_id UUID` | 환자별 감사 로그 조회 |

### 1-2. 신규 테이블 추가

| 테이블 | 이유 |
|--------|------|
| `wards` | 병동 기본 정보 관리 — AWS sync_wards 복제 원본 |
| `ward_assignments` | 환자 병상 배정 이력 — 가용 병상 계산 기준 |
| `login_history` | 로그인 이력 기록 (ISMS-P 2.9.1) |
| `password_policy` | 비밀번호 정책 설정 (ISMS-P 2.5.3) |

### 1-3. 변경 없는 기존 테이블

`departments`, `doctors`, `patients`, `diagnoses`, `clinical_notes` 는 구조 변경 없음.

---

## 2. 온프레미스 DB 테이블 목록 (hospital_onprem)

> 온프레미스는 환자 실명 등 **1등급 개인정보를 포함**합니다.  
> 외부 네트워크에서 직접 조회 불가 — 내부망 전용

### 기준 데이터

| 테이블 | 설명 |
|--------|------|
| `departments` | 진료과 목록 (내과, 심장내과, 신경과 등) |
| `doctors` | 의사 목록 및 소속 진료과 |

### 환자 임상 데이터 (1등급 포함)

| 테이블 | 설명 | 1등급 컬럼 |
|--------|------|-----------|
| `patients` | 환자 기본 정보 | `patient_name`, `phone_number`, `national_id_encrypted` |
| `encounters` | 진료 방문 이력 (날짜, 진료과, 담당의) | `chief_complaint` (주호소) |
| `diagnoses` | 진단 코드 및 진단 내용 | `diagnosis_text` |
| `clinical_notes` | 진료 임상 노트 전문 | `note_content` 전체 |
| `allergies` | 알레르기 정보 | `allergy_name` |
| `surgery_histories` | 수술 이력 | `surgery_name`, `note` |

### 입원 관리

| 테이블 | 설명 |
|--------|------|
| `wards` | 병동 정보 (이름, 유형, 전체 병상 수) |
| `ward_assignments` | 환자별 병상 배정 및 퇴원 이력 |

### 인증 / 보안 (ISMS-P)

| 테이블 | 설명 |
|--------|------|
| `users` | 온프레미스 웹앱 계정 (의사·간호사·관리자) |
| `sessions` | Refresh Token 세션 관리 |
| `login_history` | 로그인 성공/실패/잠금 이력 |
| `password_policy` | 비밀번호 정책 (길이, 복잡도, 만료일) |
| `audit_logs` | 환자 데이터 접근 전체 감사 로그 |

---

## 3. AWS DB 테이블 목록 (hospital)

> AWS는 **1등급 개인정보를 저장하지 않습니다.**  
> 환자 식별은 SHA-256 해시값만 사용합니다.

---

### 온프레미스 동기화 테이블 (sync_*)

온프레미스에서 pglogical로 단방향 복제됩니다. **AWS에서 직접 INSERT/UPDATE 금지.**

| 테이블 | 용도 | 사용하는 기능 |
|--------|------|--------------|
| `sync_departments` | 진료과 목록 저장 (내과, 심장내과 등) | 예약 신청 폼의 진료과 선택 목록 |
| `sync_doctors` | 의사 목록 및 소속 진료과 저장 | 예약 신청 폼의 의사 선택 목록, 의료진 포털 일정 조회 |
| `sync_patients` | 환자 비식별 정보 저장 (출생연도·성별·전화번호 해시) | 환자 포털 회원가입 시 본인 확인 대조 |
| `sync_encounters` | 과거 진료 방문 이력 저장 (날짜·진료과·상태) | 재진 예약 가능 여부 검증, 환자 포털 진료기록 조회 |
| `sync_diagnoses` | 진단 코드(ICD) 저장 — 진단 원문 제외 | 환자 포털 진료기록 조회 시 진단코드 표시 |
| `sync_allergies` | 알레르기 표준코드 저장 — 알레르기명 원문 제외 | (향후) 수술 전 예약 시 알레르기 확인 |
| `sync_surgery_histories` | 수술 표준코드 저장 — 수술명 원문 제외 | (향후) 수술 전 예약 시 이전 수술 이력 확인 |
| `sync_wards` | 병동명·유형·전체 병상 수·가용 병상 수 저장 | 의료진 포털 병동 현황 조회, 입원 예약 시 병동 선택 |

---

### RBAC 권한 관리 테이블

로그인한 계정의 역할에 따라 접근 가능한 메뉴와 기능을 제어합니다.

| 테이블 | 용도 | 사용하는 기능 |
|--------|------|--------------|
| `roles` | 역할 정의 (patient · doctor · nurse · admin) | 로그인 시 JWT 토큰에 역할 코드 포함 |
| `permissions` | 기능별 권한 코드 정의 (VIEW_OWN_APPOINTMENTS 등) | API 엔드포인트 접근 제어 |
| `role_permissions` | 역할과 권한의 매핑 | 역할별 허용 API 판단 |
| `menus` | 사이드바 메뉴 목록 및 페이지 URL | 로그인 후 사이드바 메뉴 렌더링 |
| `role_menus` | 역할별 표시할 메뉴 매핑 | 역할마다 다른 메뉴 구성 표시 |

---

### 인증 / 보안 테이블

| 테이블 | 용도 | 사용하는 기능 |
|--------|------|--------------|
| `users` | 포털 계정 저장 (이메일·비밀번호 해시·역할). 환자는 `patient_id_hash`로 본인 특정, 의사는 `doctor_id`로 연결 | 로그인, 회원가입, 계정 잠금 |
| `sessions` | Refresh Token 해시 저장 및 만료·폐기 관리 | 자동 로그인 유지, 토큰 갱신 |
| `user_mfa` | OTP 시크릿 저장 (현재 비활성, 추후 사용 예정) | MFA 2단계 인증 (미구현) |
| `password_policy` | 비밀번호 길이·복잡도·만료일·잠금 기준 설정 | 회원가입·비밀번호 변경 시 정책 검증, 계정 잠금 판단 |
| `login_history` | 로그인 시도 결과(성공·실패·잠금) 및 IP·기기 기록 | 관리자 로그인 이력 조회 화면 |
| `audit_logs` | 예약 생성·변경·취소, 진료기록 조회 등 모든 작업 기록 | 관리자 감사 로그 조회 화면 |

---

### 예약 테이블

| 테이블 | 용도 | 사용하는 기능 |
|--------|------|--------------|
| `appointment_types` | 예약 유형 정의 (초진·재진·입원·수술 전) 및 이전 방문 이력 필수 여부 | 예약 신청 폼 유형 선택, 재진 자격 검증 |
| `appointment_statuses` | 예약 상태 정의 (대기·확정·완료·취소·미내원) 및 종료 상태 여부 | 상태별 UI 배지, 변경 가능 여부 판단 |
| `appointments` | 예약 본체 (환자·의사·진료과·날짜·시간·메모) | 환자 예약 신청·조회·변경·취소, 원무과 예약 확정 |
| `appointment_history` | 예약의 상태·날짜·시간 변경 이력 및 변경자 기록 | (향후) 예약 변경 이력 추적 |

---

### 알림 테이블

| 테이블 | 용도 | 사용하는 기능 |
|--------|------|--------------|
| `notification_types` | 알림 유형 정의 및 이메일 제목 템플릿 저장 (예약 접수·확정·취소·계정 잠금) | 알림 발송 시 제목 템플릿 조회 |
| `notifications` | 발송된 이메일 알림 이력 및 성공·실패 상태 저장 | 예약 신청·확정·취소 시 SES 이메일 발송 기록 |

---

## 4. 테스트 로그인 방법

**공통 비밀번호**: `Test1234!`

---

### 온프레미스 HIS — http://localhost:5502

| 계정 | 역할 | 테스트 가능 기능 |
|------|------|-----------------|
| `doctor@onprem.local` | 의사 | 오늘 진료 목록 조회, 환자 실명 검색, 진료 기록·진단·임상노트·알레르기·수술이력 조회 |
| `nurse@onprem.local` | 간호사/원무과 | 환자 검색, 병동 현황, 수동 예약 등록, 병상 배정 |
| `admin@onprem.local` | 관리자 | 사용자 계정 관리, 감사 로그, 로그인 이력 조회 |

**온프레미스 테스트용 환자 데이터**

| 환자명 | 전화번호 | 생년 | 성별 |
|--------|---------|------|------|
| 김민준 | 010-1111-2222 | 1985 | M |
| 이지은 | 010-3333-4444 | 1992 | F |
| 박성호 | 010-5555-6666 | 1978 | M |

---

### AWS 환자 포털 — http://localhost:5500

| 계정 | 역할 | 테스트 가능 기능 |
|------|------|-----------------|
| `patient@test.com` | 환자 | 예약 신청·조회·변경·취소, 진료기록 조회(비식별), 비밀번호 변경, 개인정보(이메일) 수정 |

> 환자 포털 회원가입 시 생년·성별·전화번호로 본인 확인 → `sync_patients`의 해시값과 대조합니다.

---

### AWS 의료진 포털 — http://localhost:5501

| 계정 | 역할 | 테스트 가능 기능 |
|------|------|-----------------|
| `nurse@test.com` | 간호사/원무과 | 예약 현황 조회, 예약 상태 변경 (확정·완료·취소), 병동 현황 조회 |
| `doctor@test.com` | 의사 | 오늘 진료 일정 조회 (날짜 필터) |
| `admin@test.com` | 관리자 | 사용자 계정 관리, 역할/권한 관리, 보안 정책, 감사 로그, 로그인 이력 |

---

## 5. 온프레미스 DB 실행 명령어

### 5-1. 스키마 패치 (순서 중요)

```bash
# 1단계 — pglogical 복제용 컬럼/테이블 추가
psql -U <계정> -d <DB명> -f scripts/onprem-schema-patch.sql

# 2단계 — 웹앱 인증/보안 컬럼/테이블 추가
psql -U <계정> -d <DB명> -f scripts/onprem-webapp-init.sql
```

> 두 파일 모두 `IF NOT EXISTS` 조건을 사용하므로 재실행해도 오류 없음

---

### 5-2. 참조 데이터 INSERT

`onprem-webapp-init.sql` 실행 시 `password_policy`는 자동 삽입됩니다.  
아래는 추가로 직접 실행해야 하는 항목입니다.

#### 테스트 계정 (비밀번호: `Test1234!`)

```sql
-- bcrypt(cost=12) hash of 'Test1234!'
INSERT INTO users (email, password_hash, role, doctor_id, is_active)
VALUES (
    'doctor@onprem.local',
    '$2b$12$Xa7YOIJsVuVjpLGMkucqoei5VgsXQK9S0aQ3G9fDvTrhTYoJlmWIa',
    'doctor',
    'a1000000-0000-0000-0000-000000000001',
    TRUE
) ON CONFLICT (email) DO NOTHING;

INSERT INTO users (email, password_hash, role, is_active)
VALUES
    ('nurse@onprem.local',
     '$2b$12$Xa7YOIJsVuVjpLGMkucqoei5VgsXQK9S0aQ3G9fDvTrhTYoJlmWIa',
     'nurse', TRUE),
    ('admin@onprem.local',
     '$2b$12$Xa7YOIJsVuVjpLGMkucqoei5VgsXQK9S0aQ3G9fDvTrhTYoJlmWIa',
     'admin', TRUE)
ON CONFLICT (email) DO NOTHING;
```

> `doctor_id`는 기존 온프레미스 DB의 실제 의사 UUID로 교체하세요.  
> 위 값(`a1000000-...`)은 로컬 개발용 샘플입니다.

---

### 5-3. 전체 실행 순서 요약

```
1. onprem-schema-patch.sql   (스키마 패치)
2. onprem-webapp-init.sql    (웹앱 초기화 + password_policy INSERT 포함)
3. 테스트 계정 INSERT         (위 5-2 명령어)
```

---

## 6. 시스템 간 데이터 흐름 요약

```
온프레미스 DB (hospital_onprem)
  patients / encounters / diagnoses / ...
        │
        │  pglogical 단방향 복제 (온프레미스 → AWS만 허용)
        ▼
AWS RDS (hospital)
  sync_patients / sync_encounters / sync_diagnoses / ...
        │
        │  환자 포털 / 의료진 포털이 읽기
        ▼
  appointments / notifications / audit_logs
```

> **AWS → 온프레미스 방향 접근은 보안상 완전 차단됩니다.**
