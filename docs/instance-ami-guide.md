# EC2 인스턴스 & AMI 선택 가이드
> 팀 프로젝트: MZ 클리닉 병원 시스템 (ap-south-2 리전 기준)

---

## 1. 인스턴스 타입 선택: t3.large

### 선택 기준

#### 리전 지원 여부 확인
ap-south-2(하이데라바드)는 2022년 런칭된 신규 리전으로 일부 인스턴스 타입이 미지원입니다.
CLI로 직접 확인한 결과:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.large,t3a.large,t3a.medium,m5.large,m5.xlarge" \
  --region ap-south-2 \
  --query "InstanceTypeOfferings[].{Type:InstanceType,AZ:Location}" \
  --output table
```

```
t3a.large  → 미지원
t3a.medium → 미지원
t3.large   → ap-south-2a, ap-south-2b, ap-south-2c 모두 지원 ✓
m5.large   → ap-south-2a, ap-south-2b, ap-south-2c 모두 지원 ✓
```

#### 메모리 요구사항

EC2 한 대에 올라오는 구성 (ECS + Wazuh 에이전트):

```
patient 태스크 (nginx-patient + api-patient) → 1.5GB
staff   태스크 (nginx-staff  + api-staff  ) → 1.5GB
ECS 에이전트 + OS 오버헤드                  → 0.6GB
Wazuh 에이전트 (클라이언트만 설치)           → 0.1GB
────────────────────────────────────────────────────
합계                                          3.7GB
여유 (Auto Scaling 시 태스크 추가 수용)        4.3GB
```

> Wazuh 서버는 별도 EC2에 설치되므로 ECS EC2에는 Wazuh **에이전트(클라이언트)만** 설치됩니다.
> 에이전트는 약 100MB 수준으로 인스턴스 사양에 영향을 주지 않습니다.

#### 비용 비교

```
t3.large  : 약 $44/대 × 3대 = $132/월
m5.large  : 약 $72/대 × 3대 = $216/월  (동일 스펙, 더 비쌈)
```

동일 3개 AZ 지원 인스턴스 중 t3.large가 가장 비용 효율적입니다.

---

### t3.large 상세 스펙

| 항목 | 값 |
|---|---|
| vCPU | 2 |
| 메모리 | 8GB |
| 네트워크 | 최대 5Gbps |
| EBS 최적화 | 기본 지원 |
| CPU 크레딧 | 버스트 가능 (T 시리즈) |
| 아키텍처 | x86_64 |
| 가상화 | HVM |

#### T 시리즈 버스트 특성
평상시 낮은 CPU 사용 시 크레딧을 적립하고, 트래픽 급증 시 크레딧을 소모해 최대 성능을 냅니다.
병원 특성상 평상시 트래픽이 낮고 특정 시간대에 집중되는 패턴이라 T 시리즈가 적합합니다.

---

## 2. AMI 선택

### ECS EC2 (환자/의료진 포털 서버)

**Amazon ECS-Optimized Amazon Linux 2 (AL2) x86_64 AMI** 사용

#### 선택 이유

| 항목 | 내용 |
|---|---|
| 아키텍처 | x86_64 → t3.large와 일치 |
| ap-south-2 지원 | CLI 확인 완료 |
| Docker | 사전 설치 (ECS 컨테이너 실행에 필수) |
| ECS 에이전트 | 사전 설치 (ECS 클러스터 등록에 필수) |
| Wazuh 에이전트 | Amazon Linux 2 공식 지원, user_data로 추가 설치 |

#### AL2023 미사용 이유
Amazon Linux 2023 ECS 최적화 AMI는 ap-south-2 **미지원**으로 AL2를 사용합니다.

```bash
# ap-south-2 AL2 ECS AMI 지원 확인
aws ssm get-parameter \
  --name "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id" \
  --region ap-south-2 \
  --query "Parameter.Value" --output text

# 결과: ami-0ba5a7753818e4572 ✓
```

#### AMI ID 하드코딩 금지
AMI ID는 AWS 보안 패치 시 변경됩니다. Terraform에서는 SSM 파라미터로 자동 조회합니다:

```hcl
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}
```

이렇게 하면 AWS가 AMI를 업데이트해도 코드 수정 없이 항상 최신 보안 패치가 적용된 이미지를 사용합니다.

---

### Wazuh 서버 EC2

**일반 Amazon Linux 2 AMI** 사용 (ECS 최적화 버전 아님)

Wazuh 서버는 컨테이너를 실행하지 않으므로 Docker, ECS 에이전트가 불필요합니다.

```bash
# Wazuh 서버용 일반 Amazon Linux 2 AMI 조회
aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2" \
  --region ap-south-2 \
  --query "Parameter.Value" --output text
```

#### Wazuh 서버 권장 사양

| 항목 | 최소 | 권장 (병원 운영) |
|---|---|---|
| vCPU | 2 | 4 |
| 메모리 | 4GB | 8GB |
| 스토리지 | 50GB | 100GB+ |

ap-south-2 지원 인스턴스 중 권장:
```
m5.large  : 2 vCPU, 8GB  → 최소 운영 가능
m5.xlarge : 4 vCPU, 16GB → 권장 (로그 수집 부하 고려)
```

---

## 3. AMI 종류 및 비용

### AMI 비용
AWS 공식 제공 AMI(Amazon Linux 2 등)는 **무료**입니다.
비용이 발생하는 항목:
```
EC2 인스턴스 시간 요금  ← 여기서만 과금
EBS 스토리지 요금
데이터 전송 요금
```

### Community AMI 사용 금지
병원 프로젝트에서 Community AMI 사용을 금지합니다.

| 이유 | 내용 |
|---|---|
| 보안 | 출처 불명확한 이미지에 악성코드 포함 가능성 |
| ISMS-P | 2.10.1 보안시스템 운영 기준 위반 가능 |
| 유지보수 | AWS 공식 AMI는 Amazon이 보안 패치 직접 관리 |

**이 프로젝트에서는 AWS 공식 AMI만 사용합니다.**

### AWS 콘솔에서 AMI 확인 방법
```
EC2 → 이미지 → AMI 카탈로그
  → 소유자 별칭: "amazon" 표시된 것만 공식 AMI
  → 검색: amzn2-ami-ecs-hvm   ← ECS 최적화
  → 검색: amzn2-ami-hvm       ← 일반 Amazon Linux 2
```

---

## 4. 비용 최적화

병원은 장기 운영이므로 **3년 Compute Savings Plan** 적용을 권장합니다.

| 옵션 | 월 비용 | 절감 | 조건 |
|---|---|---|---|
| On-Demand | $132 | - | 약정 없음 |
| 1년 Savings Plan | $92 | 30% | 1년 약정 |
| **3년 Savings Plan** | **$66** | **50%** | **3년 약정** |

#### Savings Plan이 Reserved Instance보다 유리한 이유
- 인스턴스 타입 변경해도 할인 적용 (RI는 t3.large 고정)
- 리전 변경해도 적용
- 나중에 Fargate 전환 시에도 적용

> 현재는 인프라 구축 중이므로 ALB, ECS apply 완료 후 안정 운영 확인하고 구매 권장

---

## 5. 요약

| 구분 | 선택 | 이유 |
|---|---|---|
| ECS EC2 인스턴스 | t3.large | 3개 AZ 지원, 비용 효율, 메모리 충분 |
| ECS AMI | AL2 ECS 최적화 | Docker/ECS 에이전트 사전 설치, AL2023 미지원 |
| Wazuh 서버 인스턴스 | m5.large 이상 | Wazuh 권장 사양 |
| Wazuh 서버 AMI | 일반 AL2 | Docker/ECS 불필요 |
| 비용 최적화 | 3년 Savings Plan | 50% 절감, 장기 운영 병원에 최적 |
