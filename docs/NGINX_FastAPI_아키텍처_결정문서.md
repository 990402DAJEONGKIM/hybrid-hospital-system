# NGINX + FastAPI 아키텍처 결정 문서

> 작성일: 2026-05-19
> 대상: 김이박 클리닉 병원 포털 시스템
> 목적: NGINX / FastAPI 구조 결정 배경 및 전체 아키텍처 정리

---

## 1. NGINX 도입 결정

### 결정 사항
NGINX를 사용한다.

### 이유

| 관점 | 내용 |
|------|------|
| **유지보수** | 프론트엔드(정적 파일)와 백엔드(API)를 독립적으로 배포 가능 |
| **보안** | FastAPI가 인터넷에 직접 노출되지 않음. NGINX만 외부 접점 |
| **역할 분리** | NGINX = 정적 파일 서빙 + 리버스 프록시 / FastAPI = API 처리만 |

### ALB만 사용할 경우와 비교

| 기능 | ALB만 | ALB + NGINX |
|------|-------|-------------|
| HTTPS 종료 | ✅ ALB | ✅ ALB |
| 정적 파일 서빙 | ❌ (S3+CloudFront 필요) | ✅ NGINX 직접 서빙 |
| FastAPI 인터넷 노출 | ALB → FastAPI 직접 | ALB → NGINX → FastAPI |
| 프론트/백 독립 배포 | ❌ | ✅ |

### S3 정적 웹 호스팅 사용 여부
**사용하지 않는다.**
HTML/JS/CSS 파일은 NGINX Docker 이미지 안에 내장하여 배포한다.
파일 수정 시 NGINX 이미지를 재빌드하고 ECS Service만 재배포하면 된다.

---

## 2. 서비스 분리 결정

### 결정 사항
환자 서비스와 의료진 서비스를 **4개 ECS Service로 논리적 분리**한다.

### 4개 서비스

| 서비스 | 역할 | 접근 경로 |
|--------|------|-----------|
| `nginx-patient` | 환자 정적 파일 서빙 + api-patient 프록시 | Public ALB |
| `api-patient` | 환자 REST API | nginx-patient 경유만 |
| `nginx-staff` | 의료진 정적 파일 서빙 + api-staff 프록시 | Internal ALB (VPN 전용) |
| `api-staff` | 의료진 REST API | nginx-staff 경유만 |

### 분리 이유

| 이유 | 설명 |
|------|------|
| **독립 배포** | 환자 서비스 수정 시 의료진 서비스 영향 없음 |
| **독립 복구** | Task 크래시 시 해당 Service만 자동 재시작 |
| **독립 스케일** | api-patient Task만 증가 가능 |
| **보안 격리** | 네트워크/애플리케이션/데이터 레벨 분리 |

---

## 3. EC2 구성 결정

### 결정 사항
**AZ당 EC2 1대, 총 3대 (단일 ASG)** 로 운영한다.

### 검토 과정

처음에는 환자/의료진 EC2 그룹을 분리(6대)하는 방안을 검토했으나
아래 이유로 3대 구조로 확정했다.

#### 6대 구조 검토 시 문제점

| 문제 | 내용 |
|------|------|
| Wazuh 에이전트 | 6대 → 에이전트 6개 관리 필요 |
| ASG 2개 관리 | 운영 복잡도 증가 |
| 비용 | EC2 비용 2배 |
| 스케일링 | 환자 트래픽 급증 시 의료진 Task도 불필요하게 증가 |

#### 3대 구조의 단점

| 단점 | 심각도 | 비고 |
|------|--------|------|
| 자원 경쟁 | ⚠️ 중간 | 환자 트래픽이 의료진 성능에 영향 가능 |
| EC2 레벨 보안 격리 약화 | ⚠️ 중간 | 컨테이너 탈출 시 교차 접근 가능성 |
| EC2 장애 시 4개 Task 동시 영향 | ⚠️ 중간 | 단, 3 AZ 구성으로 다른 AZ가 처리 |

#### 3대 구조로 확정한 근거

**ISMS-P 요구사항이 이미 기존 구조에서 충족되기 때문이다.**

| ISMS-P 항목 | 요구사항 | 현재 대응 방안 | 충족 여부 |
|-------------|---------|---------------|---------|
| 2.6.1 네트워크 접근통제 | 구간별 접근통제 | Public ALB / Internal ALB + Security Group | ✅ |
| 2.6.2 정보시스템 접근통제 | 역할 기반 접근통제 | JWT role + API 엔드포인트 분리 | ✅ |
| 2.10.4 개인정보처리시스템 분리 | 시스템 분리 | 네트워크·앱·데이터 논리 분리로 충족 | ✅ |
| 2.12.1 재해복구 | 서비스 연속성 | 3 AZ + Aurora HA + ASG + ECS 자동복구 | ✅ |

---

## 4. ISMS-P 대응 방안 상세

### 개인정보 처리 시스템 분리

```
네트워크 레벨 (물리적 분리 효과)
  Public ALB   → 환자 서비스만 연결
  Internal ALB → 의료진 서비스만 연결 (VPN 전용)
  Security Group → 서비스별 독립 적용

애플리케이션 레벨 (논리적 분리)
  ECS Service 4개로 완전 분리
  JWT role 기반 접근통제
  환자 API / 의료진 API 코드 레벨 분리

데이터 레벨
  patient_id_hash로 환자 데이터 익명화
  role에 따라 조회 가능 데이터 제한
```

### 장애 시 서비스 연속성

```
인프라 레벨
  3 AZ 구성 (AZ-a, AZ-b, AZ-c)
  ALB Health Check → 비정상 Target 자동 제외
  ASG → EC2 장애 시 자동 복구

DB 레벨
  Aurora Multi-AZ
  Writer(AZ-a) + Reader(AZ-b, AZ-c)
  AZ 장애 시 자동 Failover

컨테이너 레벨
  ECS Service → Task 크래시 시 자동 재시작
  Task 3개 (AZ당 1개) → 1개 중단 시 2개 운영 유지
```

---

## 5. 전체 아키텍처

```
인터넷 (환자)                              VPN (의료진)
      │                                         │
      ▼                                         ▼
┌─────────────┐                       ┌──────────────────┐
│  Public ALB │                       │  Internal ALB     │
│  (공인 IP)  │                       │  (사설 IP만 보유) │
└──────┬──────┘                       └────────┬─────────┘
       │                                        │
       ▼                                        ▼
┌──────────────────────────────────────────────────────────────┐
│  ECS Cluster  "hospital-cluster"  (단일 ASG, EC2 총 3대)     │
│                                                              │
│  AZ-a                AZ-b                AZ-c               │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐     │
│  │ EC2 t3.medium│   │ EC2 t3.medium│   │ EC2 t3.medium│     │
│  │ Wazuh Agent  │   │ Wazuh Agent  │   │ Wazuh Agent  │     │
│  │              │   │              │   │              │     │
│  │ ┌──────────┐ │   │ ┌──────────┐ │   │ ┌──────────┐ │     │
│  │ │Task      │ │   │ │Task      │ │   │ │Task      │ │     │
│  │ │nginx-    │ │   │ │nginx-    │ │   │ │nginx-    │ │     │
│  │ │patient   │ │   │ │patient   │ │   │ │patient   │ │     │
│  │ │:80       │ │   │ │:80       │ │   │ │:80       │ │     │
│  │ └────┬─────┘ │   │ └────┬─────┘ │   │ └────┬─────┘ │     │
│  │ ┌────▼─────┐ │   │ ┌────▼─────┐ │   │ ┌────▼─────┐ │     │
│  │ │Task      │ │   │ │Task      │ │   │ │Task      │ │     │
│  │ │api-      │ │   │ │api-      │ │   │ │api-      │ │     │
│  │ │patient   │ │   │ │patient   │ │   │ │patient   │ │     │
│  │ │:8000     │ │   │ │:8000     │ │   │ │:8000     │ │     │
│  │ └──────────┘ │   │ └──────────┘ │   │ └──────────┘ │     │
│  │              │   │              │   │              │     │
│  │ ┌──────────┐ │   │ ┌──────────┐ │   │ ┌──────────┐ │     │
│  │ │Task      │ │   │ │Task      │ │   │ │Task      │ │     │
│  │ │nginx-    │ │   │ │nginx-    │ │   │ │nginx-    │ │     │
│  │ │staff     │ │   │ │staff     │ │   │ │staff     │ │     │
│  │ │:80       │ │   │ │:80       │ │   │ │:80       │ │     │
│  │ └────┬─────┘ │   │ └────┬─────┘ │   │ └────┬─────┘ │     │
│  │ ┌────▼─────┐ │   │ ┌────▼─────┐ │   │ ┌────▼─────┐ │     │
│  │ │Task      │ │   │ │Task      │ │   │ │Task      │ │     │
│  │ │api-      │ │   │ │api-      │ │   │ │api-      │ │     │
│  │ │staff     │ │   │ │staff     │ │   │ │staff     │ │     │
│  │ │:8000     │ │   │ │:8000     │ │   │ │:8000     │ │     │
│  │ └──────────┘ │   │ └──────────┘ │   │ └──────────┘ │     │
│  └──────────────┘   └──────────────┘   └──────────────┘     │
│                                                              │
│  EC2 총 3대 / Task(파드) 총 12개 / Wazuh 에이전트 3개        │
│  ← ──────────── 단일 ASG 자동 확장 (최대 9대) ─────────── → │
└──────────────────────────────────────────────────────────────┘
                           │
                           ▼
          ┌────────────────────────────────┐
          │  Aurora PostgreSQL Cluster     │
          │  Writer(AZ-a) Reader(AZ-b,c)  │
          └────────────────────────────────┘
```

---

## 6. Auto Scaling 구조

### 두 단계 자동 확장

```
1단계: ECS Service Auto Scaling (Task 증가)
  → EC2 추가 없이 기존 EC2 안에서 Task만 늘어남
  → 빠른 대응 가능

2단계: EC2 ASG (EC2 증가)
  → 기존 EC2 자원(CPU/메모리)이 한계에 도달했을 때
  → 새 EC2 추가 + Wazuh Agent 자동 설치 (User Data)
  → 새 EC2에 Task 자동 배치
```

### Service별 Auto Scaling 정책

| Service | 최소 Task | 최대 Task | 스케일 기준 |
|---------|-----------|-----------|------------|
| nginx-patient | 3 | 9 | ALB 요청 수 |
| api-patient | 3 | 12 | CPU / 요청 수 |
| nginx-staff | 3 | 3 | 고정 (의료진 소규모) |
| api-staff | 3 | 3 | 고정 (의료진 소규모) |

### 환자 트래픽 급증 시나리오

```
평상시
  EC2 3대, Task 12개, Wazuh 에이전트 3개

트래픽 소폭 증가 (Task만 증가)
  EC2 3대 유지
  api-patient: 3개 → 6개 (기존 EC2에 추가 배치)
  Wazuh 에이전트 추가 없음

트래픽 대폭 증가 (EC2도 증가)
  EC2: 3대 → 최대 9대
  신규 EC2: Wazuh 에이전트 자동 설치 (User Data)
  신규 EC2에 Task 자동 배치
  의료진 Task도 올라오나 허용 가능한 수준

AZ-b 장애 시
  ALB: AZ-b 제외, AZ-a / AZ-c로 트래픽 전환
  ASG: AZ-a, AZ-c에 EC2 자동 추가
  서비스 중단 없음
```

---

## 7. Internal ALB 개념

### Internal ALB ≠ IP 화이트리스트

두 가지가 **함께** 적용되어 의료진 전용 접근 통제를 구현한다.

| 개념 | 설명 | 설정 위치 |
|------|------|-----------|
| **Internal ALB** | 공인 IP가 없는 ALB. 인터넷에서 DNS 조회 자체 불가 | AWS ALB 타입 설정 |
| **IP 화이트리스트** | 병원 내부망 CIDR만 허용하는 규칙 | Internal ALB Security Group |

```
병원 내부망 (온프레미스 172.30.1.0/24)
  │
  │ 1차: Site-to-Site VPN 터널 없으면 AWS VPC 진입 불가
  ▼
VPN 터널 통과
  │
  │ 2차: Internal ALB Security Group
  │      172.30.1.0/24 이외 IP 차단
  ▼
Internal ALB (사설 IP: 10.x.x.x)
  │
  ▼
nginx-staff → api-staff
```

---

## 8. Wazuh 에이전트 운영 방식

### 서버는 베어메탈, 에이전트는 EC2에 직접 설치

```
Wazuh 서버 (별도 EC2 t3.xlarge — 베어메탈 설치)
  Ubuntu 22.04에 직접 설치
  Ansible 플레이북으로 자동 구성
  terraform/aws/wazuh2/ 에 구현됨
  │
  │ 로그 수집
  ├── EC2 (AZ-a) — Wazuh Agent (베어메탈)
  │     └── 컨테이너: nginx-patient, api-patient
  │                   nginx-staff, api-staff
  ├── EC2 (AZ-b) — Wazuh Agent
  └── EC2 (AZ-c) — Wazuh Agent
```

### 컨테이너 안에 에이전트를 넣지 않는 이유

```
컨테이너 안에 설치 시
  → 컨테이너 재시작 시 에이전트도 재시작
  → EC2 OS 레벨 이상 감지 불가
  → ECS 장애 시 Wazuh도 함께 중단

EC2에 직접 설치 시
  → 컨테이너와 무관하게 항상 실행
  → EC2 OS 레벨 + 컨테이너 레벨 모두 감시
  → ECS 장애 시에도 모니터링 유지
```

### ASG 자동 확장 시 에이전트 처리

```
신규 EC2 기동 시 User Data 스크립트 자동 실행
  1. Wazuh Agent 패키지 설치
  2. Wazuh 서버 IP 등록
  3. 에이전트 서비스 시작
  → 새 EC2 기동 즉시 모니터링 시작
  → 보안 모니터링 공백 없음
```

---

## 9. 4개 서비스 소스코드 대응

### nginx-patient

**담당 기능**: 환자 로그인, 회원가입, 예약 달력, 비밀번호 변경

| 파일 | 포함 여부 |
|------|-----------|
| `frontend/login.html` | ✅ |
| `frontend/signup.html` | ✅ (환자만 회원가입) |
| `frontend/index.html` | ✅ (환자 UI) |
| `frontend/change-password.html` | ✅ |
| `frontend/css/style.css` | ✅ |
| `frontend/js/config.js` | ✅ |
| `frontend/js/script.js` | ✅ (환자 기능) |
| `frontend/js/main.js` | ✅ |
| `nginx.conf` (신규) | ✅ |

```dockerfile
FROM nginx:alpine
COPY frontend/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf
```

---

### api-patient

**담당 API**: `/auth/*`, `/portal/appointments/*`

| 파일 | 포함 여부 |
|------|-----------|
| `backend/main.py` | ✅ (auth + portal 환자 라우터만) |
| `backend/core/database.py` | ✅ |
| `backend/core/security.py` | ✅ |
| `backend/core/middleware.py` | ✅ |
| `backend/models/db.py` | ✅ |
| `backend/routers/auth.py` | ✅ |
| `backend/routers/portal.py` | ✅ (appointments만) |
| `backend/routers/admin.py` | ❌ |

```dockerfile
FROM python:3.11-slim
COPY backend/ /app/
RUN pip install -r /app/requirements.txt
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

---

### nginx-staff

**담당 기능**: 의료진 로그인, 진료 일정, 환자 목록, 관리자 기능, 비밀번호 변경

| 파일 | 포함 여부 |
|------|-----------|
| `frontend/login.html` | ✅ |
| `frontend/signup.html` | ❌ (의료진은 관리자가 계정 생성) |
| `frontend/index.html` | ✅ (의료진 UI) |
| `frontend/change-password.html` | ✅ |
| `frontend/css/style.css` | ✅ |
| `frontend/js/config.js` | ✅ |
| `frontend/js/script.js` | ✅ (의료진 기능) |
| `frontend/js/main.js` | ✅ |
| `nginx.conf` (신규) | ✅ |

```dockerfile
FROM nginx:alpine
COPY frontend/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf
```

---

### api-staff

**담당 API**: `/auth/*`, `/portal/doctor/*`, `/admin/*`

| 파일 | 포함 여부 |
|------|-----------|
| `backend/main.py` | ✅ (auth + portal 의료진 + admin 라우터만) |
| `backend/core/database.py` | ✅ |
| `backend/core/security.py` | ✅ |
| `backend/core/middleware.py` | ✅ |
| `backend/models/db.py` | ✅ |
| `backend/routers/auth.py` | ✅ |
| `backend/routers/portal.py` | ✅ (doctor만) |
| `backend/routers/admin.py` | ✅ |

```dockerfile
FROM python:3.11-slim
COPY backend/ /app/
RUN pip install -r /app/requirements.txt
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

---

## 10. ECR 이미지 저장소

| ECR 저장소 | 용도 |
|-----------|------|
| `hospital-nginx-patient` | 환자 NGINX 이미지 |
| `hospital-api-patient` | 환자 FastAPI 이미지 |
| `hospital-nginx-staff` | 의료진 NGINX 이미지 |
| `hospital-api-staff` | 의료진 FastAPI 이미지 |

---

## 11. 보안 그룹 흐름

```
인터넷
  │
Public ALB SG        (80, 443 허용)
  │
nginx-patient SG     (Public ALB SG에서만 :80 허용)
  │
api-patient SG       (nginx-patient SG에서만 :8000 허용)
  │
RDS SG               (api-patient SG에서 :5432 허용)


VPN (172.30.1.0/24)
  │
Internal ALB SG      (병원 내부망 CIDR만 허용)
  │
nginx-staff SG       (Internal ALB SG에서만 :80 허용)
  │
api-staff SG         (nginx-staff SG에서만 :8000 허용)
  │
RDS SG               (api-staff SG에서도 :5432 허용)
```

---

## 12. NGINX 실행 방식

NGINX는 EC2에 베어메탈로 설치하지 않는다. **Docker 컨테이너로 실행**한다.

| 구분 | EC2에 직접 설치 | 컨테이너 안에 존재 |
|------|----------------|------------------|
| Docker 엔진 | ✅ | - |
| ECS Agent | ✅ | - |
| Wazuh Agent | ✅ | - |
| NGINX | ❌ | ✅ |
| Python / FastAPI | ❌ | ✅ |
| HTML / JS / CSS | ❌ | ✅ |

---

## 13. 현재 소스코드 분리 시 필요한 작업

| 파일 | 현재 상태 | 분리 방향 |
|------|-----------|-----------|
| `frontend/index.html` | 환자 + 의료진 UI 혼재 | 환자용 / 의료진용 분리 |
| `frontend/js/script.js` | 환자 + 의료진 로직 혼재 | script-patient.js / script-staff.js 분리 |
| `backend/routers/portal.py` | 환자 + 의료진 API 혼재 | patient용 / staff용 분리 |
| `backend/main.py` | 전체 라우터 등록 | patient용 / staff용 등록 분리 |




## 가격






# 