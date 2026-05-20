# ECS 스케일링 및 배치 가이드
> 팀 프로젝트: MZ 클리닉 병원 시스템

---

## 1. ASG 기본 설정

EC2 2대를 상시 운영하고, 트래픽 급증 시 1대를 추가해 최대 3대로 운영합니다.

```hcl
# terraform/aws/ecs/variables.tf
asg_min_size     = 2   # 항상 2대 유지
asg_max_size     = 3   # 최대 3대
asg_desired_size = 2   # 초기 2대
```

### 2대 상시 운영 이유

awsvpc 네트워크 모드에서 태스크마다 ENI 1개가 할당됩니다.

```
t3.large ENI 최대: 3개
  ENI 0: EC2 기본
  ENI 1: patient-task
  ENI 2: staff-task
  → 꽉 참
```

EC2 1대로 운영하면 배포 시 기존 태스크와 새 태스크가 동시에 필요해 ENI가 부족합니다.
2대 상시 운영으로 롤링 배포 시 한 쪽 EC2에서 트래픽을 처리하면서 다른 쪽을 교체합니다.

```
배포 시:
  EC2 #1: patient-task(구) + staff-task(구) → 트래픽 처리 중
  EC2 #2: patient-task(신) + staff-task(신) → 교체 진행
  → 다운타임 없음
```

---

## 2. 콜드 스타트 문제와 Warm Pool

### 문제

트래픽 급증으로 ASG가 EC2 3대째를 추가할 때 새 인스턴스 부팅에 시간이 걸립니다.

```
ASG 스케일 아웃 결정
  → EC2 부팅 (AMI 로딩)       약 2~3분
  → ECS 에이전트 클러스터 등록  약 30초
  → ECS 태스크 배포            약 30초
  ──────────────────────────────────────
  총 약 3~4분 지연
```

### 해결: Warm Pool

미리 초기화가 완료된 Stopped 인스턴스를 대기시킵니다.

```
Warm Pool (Stopped 상태 대기)
  → 스케일 아웃 시 Start만 하면 됨
  → AMI 로딩 과정 생략
  ──────────────────────────────
  총 약 60~90초로 단축
```

```hcl
# terraform/aws/ecs/compute.tf (aws_autoscaling_group 내부)
warm_pool {
  pool_state                  = "Stopped"
  min_size                    = 1
  max_group_prepared_capacity = 2

  instance_reuse_policy {
    reuse_on_scale_in = true
  }
}
```

### Warm Pool 비용

Stopped 상태 = 인스턴스 시간 요금 없음, EBS 비용만 과금

```
EBS 30GB × $0.08/GB = $2.4/월
```

---

## 3. ECS 서비스 배포 설정

```hcl
desired_count                      = 2   # EC2 2대에 각 1개씩
deployment_minimum_healthy_percent = 50  # 최소 1개 유지하며 교체
deployment_maximum_percent         = 100 # 동시 최대 2개 (ENI 한계 초과 방지)
```

`maximum_percent = 100`으로 설정하면 기존 태스크를 중지한 후 새 태스크를 시작합니다.
EC2 2대이므로 한 대에서 교체가 일어나는 동안 나머지 한 대가 트래픽을 처리합니다.

---

## 4. 월 비용

```
EC2 t3.large 2대:  $44 × 2 = $88/월
EBS 30GB 2대:      $2.4 × 2 = $4.8/월
Warm Pool EBS 1대: $2.4/월
──────────────────────────────────────
합계:              약 $95/월

트래픽 급증으로 3대 운영 시:
  EC2 3대: $132/월 + EBS $7.2/월 = $139.2/월
```

---

## 5. 전체 동작 구조

```
평상시: EC2 2대 상시 운영
  EC2 #1: patient-task + staff-task
  EC2 #2: patient-task + staff-task

트래픽 급증:
  Capacity Provider 감지
  → Warm Pool Stopped 인스턴스 Start (60~90초)
  → EC2 3대로 확장
  → 태스크 추가 배포

스케일 인:
  트래픽 감소 감지
  → EC2 #3 태스크 제거
  → EC2 #3 종료 후 Warm Pool로 반환 (reuse_on_scale_in)
```

---

## 6. EBS 배치 위치

EBS는 EC2 인스턴스와 동일한 AZ에 자동 배치됩니다.

```
ap-south-2a → EC2 + EBS (app-subnet-a)
ap-south-2b → EC2 + EBS (app-subnet-b)
ap-south-2c → EC2 + EBS (app-subnet-c, 트래픽 급증 시)
```

인스턴스 교체 시 기존 EBS는 삭제됩니다 (`delete_on_termination = true`).

---

## 7. 안정화 후 비용 최적화

현재 인프라 구축 단계이므로 On-Demand로 운영합니다. 안정적인 운영이 확인되면 Savings Plan 적용으로 비용을 절감할 수 있습니다.

| 옵션 | 비용 절감 | 조건 |
|---|---|---|
| On-Demand | - | 약정 없음 |
| 1년 Savings Plan | 약 30% | 1년 약정 |
| 3년 Savings Plan | 약 50% | 3년 약정 |

병원은 장기 운영이므로 3년 Compute Savings Plan이 가장 유리합니다.
Savings Plan은 인스턴스 타입·리전 변경 시에도 할인이 유지됩니다.
