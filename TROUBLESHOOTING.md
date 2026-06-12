# 트러블슈팅 기록

작성일: 2026-06-12  
작성자: 김다정

---

## 목차

1. [Wazuh 감사 로그 action_type UNKNOWN 문제](#1-wazuh-감사-로그-action_type-unknown-문제)
2. [AWS 관련 파일 식별](#2-aws-관련-파일-식별)
3. [로컬 테스트 환경 구성](#3-로컬-테스트-환경-구성)

---

## 1. Wazuh 감사 로그 action_type UNKNOWN 문제

**파일 경로:** `app/combined/backend/core/middleware.py`

### 문제 현상

Wazuh에 수집되는 감사 로그의 `action_type` 필드가 대부분 `UNKNOWN`으로 기록됨.

```json
{
  "event_type":  "fastapi_audit",
  "action_type": "UNKNOWN",
  "result_code": "200",
  "path":        "/staff/emr/patients/{id}",
  ...
}
```

### 원인 분석

`middleware.py`의 `ACTION_MAP`에 등록된 경로 패턴이 실제 라우터 prefix와 불일치.

```python
# 변경 전 — prefix 없음
("POST", r"/auth/login$",       "LOGIN"),      # ^ 앵커 없음
("GET",  r"^/portal/doctor/...", "READ_..."),   # 실제 경로와 다름

# 실제 요청 경로 예시
# POST /staff/auth/login   → 매칭 실패 → UNKNOWN
# GET  /staff/emr/patients → 패턴 자체 없음 → UNKNOWN
# POST /staff/admin/users  → /staff prefix 없어서 → UNKNOWN
```

FastAPI `main.py`에서 라우터가 아래처럼 prefix를 붙여 등록되는데, `ACTION_MAP`은 이를 반영하지 않고 있었음.

```python
app.include_router(patient_auth.router,  prefix="/patient")
app.include_router(staff_auth.router,    prefix="/staff")
app.include_router(portal_auth.router,   prefix="/portal")
```

### 해결 방법

`ACTION_MAP`과 `TARGET_TABLE_MAP`을 실제 라우터 prefix 기준으로 전면 교체.

| 그룹 | prefix | 예시 action_type |
|---|---|---|
| 스태프 인증 | `/staff/auth/` | `LOGIN`, `LOGOUT`, `CHANGE_PASSWORD` |
| 스태프 포털 | `/staff/portal/` | `VIEW_DOCTOR_SCHEDULE`, `CREATE_APPOINTMENT` |
| EMR 의사 전용 | `/staff/emr/doctor/` | `VIEW_EMR`, `BREAK_GLASS`, `CREATE_ENCOUNTER` |
| EMR 공통 | `/staff/emr/` | `READ_PATIENT_DETAIL`, `ADMIT_PATIENT`, `CHECKIN` |
| 스태프 관리자 | `/staff/admin/` | `CREATE_USER`, `LOCK_USER`, `UPDATE_ROLE_PERMISSIONS` |
| 환자 포털 인증 | `/patient/auth/` | `LOGIN`, `REGISTER` |
| 환자 포털 | `/patient/portal/` | `READ_APPOINTMENTS`, `READ_MY_RECORDS` |
| 병원 포털 인증 | `/portal/auth/` | `LOGIN` |
| 병원 포털 | `/portal/` | `READ_PATIENT_DETAIL`, `VIEW_ALL_APPOINTMENTS` |

**패턴 순서 주의사항**

`ACTION_MAP`은 위에서부터 첫 번째 매칭에서 즉시 반환하므로, 구체적인 경로를 반드시 앞에 배치해야 함.

```python
# 올바른 순서 (구체적인 경로 먼저)
("GET", r"^/staff/emr/doctor/patients/search$",        "SEARCH_PATIENTS"),  # 먼저
("GET", r"^/staff/emr/doctor/patients/[^/]+/emr$",     "VIEW_EMR"),
("GET", r"^/staff/emr/doctor/patients$",               "READ_PATIENTS"),    # 마지막

# 순서가 뒤바뀌면 /staff/emr/doctor/patients/search → READ_PATIENTS로 오매칭됨
```

### Wazuh 로그 동작 흐름

```
FastAPI stdout 출력
    ↓
Docker json-file 드라이버 → /var/lib/docker/containers/*/*-json.log
    ↓
ECS EC2의 Wazuh agent → Wazuh Manager 전송
```

`_emit_wazuh_log()` 함수가 매 요청마다 아래 JSON을 stdout에 출력.

```json
{
  "event_type":  "fastapi_audit",
  "action_type": "LOGIN",
  "result_code": "200",
  "user_id":     "abc-123...",
  "role":        "doctor",
  "source_ip":   "10.0.0.1",
  "path":        "/staff/auth/login",
  "method":      "POST",
  "timestamp":   "2026-06-12T..."
}
```

- `pid`(patient_id_hash)는 stdout에 포함하지 않음 → DB에만 저장 (환자 식별정보 보호)
- `UUID_PATTERN.sub("{id}", path)` 로 경로의 UUID를 `{id}`로 마스킹 후 출력

---

## 2. AWS 관련 파일 식별

**대상 폴더:** `app/combined/backend/`

### AWS 서비스별 파일

#### AWS SES (이메일 알림)

| 파일 | 역할 |
|---|---|
| `core/ses.py` | boto3로 SES 호출, 예약 확인/변경/취소 시 이메일 발송 |
| `requirements.txt` | `boto3` 패키지 선언 |

`SES_FROM_EMAIL` 환경변수가 비어 있으면 발송을 건너뜀 → 로컬 개발 시 정상 동작.

#### AWS RDS (PostgreSQL)

| 파일 | 역할 |
|---|---|
| `core/database.py` | RDS 연결 엔진 생성 (`DATABASE_URL`은 Vault에서 주입) |
| `core/vault_loader.py` | Vault에서 `RDS_SECRET_ID` 포함 시크릿 로드 |
| `models/db.py` | `DB_MODE=cloud` 일 때 RDS 전용 스키마 적용 |

`DB_MODE` 환경변수로 클라우드(RDS) / 온프레미스 분기:

```python
DB_MODE = os.getenv("DB_MODE", "cloud")   # 기본값 = cloud(AWS RDS)

# cloud  → patient_id_hash (varchar)  컬럼 사용
# onprem → patient_id (UUID FK)       컬럼 사용
```

`DB_MODE` 분기가 적용되는 파일 목록:

- `models/db.py` — `users`, `appointments`, `audit_logs` 테이블 컬럼 구조
- `core/security.py` — JWT 토큰 생성 시 `patient_id_hash` vs `patient_id`
- `core/middleware.py` — 감사 로그 DB 저장 시 컬럼 분기
- `routers/staff/auth.py`, `emr.py`, `emr_doctor.py`, `portal.py`
- `routers/patient/auth.py`, `portal.py`
- `routers/portal_app/auth.py`, `portal.py`

#### HashiCorp Vault (AWS EC2에서 실행)

| 파일 | 역할 |
|---|---|
| `core/vault_loader.py` | Vault API 호출, DB 접속정보 등 시크릿 주입 |
| `main.py` | 앱 시작 시 `load_vault_secrets()` 최초 실행 |

`VAULT_ADDR` 미설정 시 즉시 반환 → 로컬 개발 시 환경변수 직접 사용.

---

## 3. 로컬 테스트 환경 구성

AWS 클라우드 환경을 로컬에서 재현하기 위한 Docker Compose 기반 테스트 환경.

**위치:** `local-test/`

### 파일 구성

```
local-test/
├── compose.yml          # 전체 스택 (db + api + nginx)
├── .env.example         # 환경변수 템플릿
├── Dockerfile.backend   # FastAPI 이미지 빌드
├── entrypoint.sh        # DB 테이블 초기화 + uvicorn 실행
└── nginx.local.conf     # 로컬용 nginx 설정
```

> `docker-compose.yml`은 프로젝트 루트 `.gitignore`에 등록되어 있으므로 `compose.yml`로 생성.  
> Docker Compose v2는 `compose.yml`을 자동 인식함.

### 실행 방법

```bash
cd local-test

# 1. 환경변수 파일 생성
cp .env.example .env
# 필요 시 .env의 값 수정

# 2. 전체 스택 빌드 및 실행
docker compose up --build

# 3. 중지 및 볼륨 초기화
docker compose down -v
```

### 접속 주소

| 서비스 | 주소 |
|---|---|
| 환자 포털 | http://localhost/patient/login.html |
| 스태프 | http://localhost/staff/login.html |
| 병원 포털 | http://localhost/portal/login.html |
| API 헬스체크 | http://localhost:8000/health |
| DB 직접 접속 | `postgresql://hospital_user:localtest1234@localhost:5432/hospital` |

### AWS 실제 환경 vs 로컬 테스트 환경 비교

| 항목 | AWS 실제 | 로컬 테스트 |
|---|---|---|
| DB | AWS RDS Aurora PostgreSQL | 로컬 PostgreSQL 16 (Docker) |
| DB 스키마 | `DB_MODE=cloud` | 동일하게 `DB_MODE=cloud` |
| DB SSL | `sslmode=require` | `sslmode=disable` |
| 시크릿 관리 | HashiCorp Vault | `VAULT_ADDR` 비워두고 env 직접 사용 |
| 이메일 발송 | AWS SES 실제 발송 | `SES_FROM_EMAIL` 공백 → 자동 생략 |
| 쿠키 보안 | `COOKIE_SECURE=true` (HTTPS) | `COOKIE_SECURE=false` (HTTP) |
| DB 테이블 생성 | 기존 RDS 스키마 사용 | `entrypoint.sh`에서 `create_all` 자동 실행 |
| nginx API_KEY 주입 | ECS Task Definition 환경변수 | `envsubst`로 `.env`의 `API_KEY` 치환 |

### 구동 흐름

```
docker compose up
    ↓
[db] PostgreSQL 기동 → healthcheck 통과
    ↓
[api] Dockerfile.backend 빌드
    → pip install requirements.txt
    → entrypoint.sh 실행
        → Base.metadata.create_all(engine)  # 테이블 자동 생성
        → uvicorn main:app --reload         # FastAPI 기동
    ↓
[nginx] nginx.local.conf 로드
    → envsubst로 ${API_KEY} 치환
    → 80포트 리슨, /api/* → api:8000 프록시
```

### 주요 환경변수 설명 (.env.example 기준)

| 변수 | 로컬 값 | 설명 |
|---|---|---|
| `DB_MODE` | `cloud` | AWS RDS와 동일한 스키마 사용 |
| `POSTGRES_PASSWORD` | `localtest1234` | 로컬 PostgreSQL 비밀번호 |
| `JWT_SECRET` | `local-jwt-secret-...` | JWT 서명 키 (32자 이상 권장) |
| `API_KEY` | `local-api-key-1234` | nginx가 `X-API-Key` 헤더로 주입 |
| `HASH_SALT` | `local-hash-salt-...` | 환자 식별자 SHA-256 해싱용 salt |
| `COOKIE_SECURE` | `false` | HTTP 환경이므로 false |
| `VAULT_ADDR` | (비워둠) | 비어 있으면 vault_loader 즉시 반환 |
| `SES_FROM_EMAIL` | (비워둠) | 비어 있으면 이메일 발송 생략 |
