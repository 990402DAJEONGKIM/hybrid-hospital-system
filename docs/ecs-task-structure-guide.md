# ECS 태스크 구조 가이드
> 팀 프로젝트: MZ 클리닉 병원 시스템

---

## 1. 현재 태스크 구조

EC2 한 대에 2개의 태스크가 올라옵니다.

```
EC2 (t3.large)
  ├── patient-task
  │     ├── nginx-patient  (컨테이너)
  │     └── api-patient    (컨테이너)
  └── staff-task
        ├── nginx-staff    (컨테이너)
        └── api-staff      (컨테이너)
```

ECS에서 태스크(Task)는 쿠버네티스의 파드(Pod)와 동일한 개념입니다.
컨테이너 여러 개를 하나의 태스크에 묶어서 실행합니다.

---

## 2. NGINX + FastAPI를 같은 태스크에 묶은 이유

NGINX가 FastAPI의 리버스 프록시 역할을 하기 때문입니다.

**트래픽 흐름:**
```
ALB → NGINX (port 80) → FastAPI (port 8000)
```

NGINX가 FastAPI로 요청을 넘길 때 `localhost:8000`으로 통신합니다.
같은 태스크 안에 있어야 `localhost` 통신이 가능합니다.

```nginx
upstream fastapi {
    server localhost:8000;  # 같은 태스크 내 통신
}

location /health {
    proxy_pass http://fastapi/health;
}
```

**NGINX가 수정될 일이 거의 없는 이유:**
- `/auth/`, `/portal/` 라우트 구조가 바뀌지 않는 한 고정
- 보안 헤더 설정은 한 번 세팅하면 거의 변경 없음
- SSL 종료는 ALB에서 처리하므로 NGINX 역할 최소화

---

## 3. 오토스케일링 구성

### 스케일링 단위

```
스케일링 가능:
  EC2 인스턴스  ← ASG가 관리 (min 2대, max 4대)
  ECS 태스크    ← ECS Service Auto Scaling이 관리

스케일링 불가:
  태스크 내 컨테이너  ← 개별 스케일링 없음 (태스크가 최소 단위)
```

컨테이너 내부에서 트래픽 처리를 늘리는 방법:
- **NGINX**: `worker_processes auto` — CPU 코어 수만큼 자동으로 워커 생성
- **FastAPI**: `--workers 2` — 현재 고정 2개, 태스크 자체를 늘려서 대응

### ECS 서비스 오토스케일링 조건

| 항목 | patient 서비스 | staff 서비스 |
|---|---|---|
| 최소 태스크 | 2개 | 2개 |
| 최대 태스크 | 6개 | 없음 |
| 스케일 아웃 조건 | CPU 평균 70% 초과 | 없음 |
| 스케일 아웃 대기 | 60초 | - |
| 스케일 인 조건 | CPU 평균 70% 미만 | 없음 |
| 스케일 인 대기 | 300초 | - |

### EC2 ASG 조건

| 항목 | 값 |
|---|---|
| 최소 인스턴스 | 2대 |
| 최대 인스턴스 | 4대 |
| 스케일링 기준 | ECS Capacity Provider 자동 관리 |
| 헬스체크 | EC2 상태 기반 |
| 헬스체크 유예 기간 | 120초 |

---

## 4. FastAPI 장애 시 동작

두 컨테이너 모두 `essential: true`로 설정되어 있습니다.

```
FastAPI 컨테이너 종료
       ↓
ECS: essential 컨테이너 장애 감지
       ↓
태스크 전체 중지 (NGINX도 함께)
       ↓
ECS가 새 태스크 시작
       ↓
FastAPI 먼저 기동 (dependsOn 조건)
       ↓
NGINX 기동
```

**ALB 동작:**
```
FastAPI 죽음
  → NGINX /health 프록시 → 502 반환
  → ALB: unhealthy 감지 → 해당 태스크 트래픽 차단
  → 나머지 2개 태스크 (다른 AZ)가 트래픽 처리
  → 새 태스크 생성 완료 → 트래픽 재개
```

사용자 입장에서는 서비스 중단 없이 자동 복구됩니다.

---

## 5. 4 태스크 분리 구조 검토

분리 구조:
```
nginx-patient-task  (별도)
api-patient-task    (별도)
nginx-staff-task    (별도)
api-staff-task      (별도)
```

### 이점

| 항목 | 내용 |
|---|---|
| 독립 재시작 | FastAPI 죽어도 NGINX 재시작 불필요 |
| 독립 스케일링 | NGINX/FastAPI 각각 다른 기준으로 스케일링 가능 |
| 독립 배포 | FastAPI 업데이트 시 NGINX 무중단 |
| 리소스 정밀 할당 | 각 컨테이너에 딱 맞는 CPU/메모리 설정 가능 |

### 단점

| 항목 | 내용 |
|---|---|
| ENI 한계 초과 | t3.large ENI 최대 3개, 4 태스크 시 ENI 5개 필요 → 불가 |
| 서비스 디스커버리 필요 | NGINX가 FastAPI IP를 동적으로 찾아야 함 → AWS Cloud Map 추가 |
| 네트워크 레이턴시 | localhost 통신 → 네트워크 통신으로 변경 |
| 구조 복잡도 증가 | NGINX conf 수정 필요 (아래 설명 참고) |

### ENI 한계가 핵심 문제

`awsvpc` 네트워크 모드에서 태스크마다 ENI 1개가 할당됩니다.

```
t3.large ENI 최대: 3개
  ENI 0: EC2 기본 통신용
  ENI 1: patient-task
  ENI 2: staff-task
  → 꽉 참

4 태스크 분리 시: ENI 5개 필요 → t3.large 불가
  → m5.xlarge (ENI 최대 4개)로 업그레이드 필요 → 비용 2배
```

### NGINX 구성 복잡도

태스크 분리 시 FastAPI IP가 재시작마다 변경됩니다.
`localhost`를 사용할 수 없어 AWS Cloud Map DNS가 필요합니다.

```nginx
# 현재 (사이드카) — 단순
upstream fastapi {
    server localhost:8000;  # 항상 고정
}

# 분리 시 — 복잡
upstream fastapi {
    server api-patient.hospital.local:8000;  # Cloud Map DNS 필요
}
```

추가로 필요한 작업:
```
nginx.conf          → localhost → Cloud Map DNS로 변경
Cloud Map 네임스페이스 → 추가 생성 (~$1.10/월)
ECS 서비스          → Cloud Map 서비스 등록 설정 추가
```

### 결론: 현재 구조 유지

- FastAPI 재시작 시간 약 10~30초 → 다른 AZ 2개 태스크가 트래픽 처리
- NGINX와 FastAPI는 어차피 함께 스케일되는 구조
- ENI 한계로 인스턴스 업그레이드 비용 발생
- NGINX 수정 빈도가 낮아 분리 이점 없음

---

## 6. ENI가 필요한 이유

태스크 정의에서 `network_mode = "awsvpc"`를 사용하기 때문입니다.

```hcl
resource "aws_ecs_task_definition" "patient" {
  network_mode = "awsvpc"
}
```

awsvpc 모드에서 태스크마다 ENI 1개가 할당되어 독립적인 IP를 가집니다.

| | awsvpc (현재) | bridge |
|---|---|---|
| ENI | 태스크마다 1개 | EC2 ENI 공유 |
| IP | 태스크마다 독립 IP | EC2 IP 공유 (포트로 구분) |
| 보안그룹 | 태스크 단위 적용 | EC2 단위만 적용 |
| ISMS-P | 네트워크 격리 충족 | 격리 부족 |

awsvpc를 사용하는 이유:
- ALB가 각 태스크 IP로 직접 트래픽 전달 가능
- 태스크별 보안그룹 적용으로 ISMS-P 네트워크 격리 요건 충족
- 태스크 간 네트워크 격리
