# KMS & Secrets Manager 팀 가이드
> 프로젝트: msp_hospital_project (김이박 클리닉)
> 작성일: 2026-05-20
> 목적: KMS 및 Secrets Manager 관련 팀원 공유용 가이드

---

## 1. KMS (Key Management Service) 개요

### KMS란?
KMS는 **암호화 키(자물쇠)를 만들고 관리하는 서비스**입니다.
실제 비밀값을 저장하는 것이 아니라, 데이터를 암호화하는 키를 관리합니다.

- 실제 암호키 재료는 **AWS HSM(Hardware Security Module)** 내부에만 존재
- AWS 직원도 키 원문을 볼 수 없음
- Terraform state에는 키 ARN(주소)만 저장되고 키 재료는 절대 노출되지 않음

### HSM이란?
암호키를 저장하고 암호화 연산을 수행하는 **전용 하드웨어 장치**입니다.
- 키가 하드웨어 칩 안에만 존재
- 물리적으로 탈취해도 키 자동 파괴
- FIPS 140-2 Level 3 인증

---

## 2. 프로젝트 KMS 구성 현황

### 키 목록 (`terraform/aws/kms/main.tf`)

| 키 이름 | Alias | 용도 | 상태 |
|---------|-------|------|------|
| `aws_kms_key.rds` | `alias/aws-kms-rds-01` | Aurora PostgreSQL 저장 데이터 암호화 | 생성됨 (현재 비활성) |
| `aws_kms_key.ebs` | `alias/aws-kms-ebs-01` | ECS EC2 EBS 볼륨 암호화 | ✅ 활성 |
| `aws_kms_key.s3` | `alias/aws-kms-s3-01` | S3 버킷 암호화 (로그/백업) | 생성됨 (S3 모듈 대기) |
| `aws_kms_key.secretsmanager` | `alias/aws-kms-sm-01` | Secrets Manager 암호화 | ✅ 활성 |
| `aws_kms_key.ecr` | `alias/aws-kms-ecr-01` | ECR 컨테이너 이미지 암호화 | ✅ 활성 |

### 키 공통 설정

```hcl
enable_key_rotation     = true   # 자동 교체 활성화
rotation_period_in_days = 365    # 1년마다 키 교체 (ISMS-P 2.7.1)
deletion_window_in_days = 30     # 삭제 후 30일 대기 (실수 방지)
```

### 각 키가 사용되는 위치

| 키 | 사용 위치 |
|----|---------|
| EBS 키 | `terraform/aws/ecs/compute.tf` → Launch Template EBS 암호화 |
| ECR 키 | `terraform/aws/ecr/main.tf` → 4개 리포지토리 이미지 암호화 |
| Secrets Manager 키 | CLI로 생성한 시크릿 3개 암호화 |
| S3 키 | S3 모듈 작성 후 적용 예정 |
| RDS 키 | 기존 클러스터 호환성으로 현재 비활성 |

---

## 3. Terraform으로 KMS를 관리해도 괜찮은가?

### 결론: 괜찮습니다

Terraform은 **키 설정(메타데이터/정책)** 만 관리하고, 실제 암호키 재료는 AWS HSM 내부에서만 존재합니다.

### Terraform이 KMS로 할 수 있는 것 vs 없는 것

| 가능 | 불가능 |
|------|--------|
| 키 생성 / 삭제 | 키 재료(암호키 원문) 조회 |
| 키 정책 설정 | 키로 암호화된 데이터 복호화 |
| 자동 교체 설정 | |
| Alias 생성 | |

### ISMS-P 2.7.1 준수 현황

| 요구사항 | 현재 설정 | 상태 |
|---------|---------|------|
| 주기적 키 교체 | `rotation_period_in_days = 365` | ✅ |
| 키 삭제 보호 | `deletion_window_in_days = 30` | ✅ |
| 키 접근 제어 | key policy로 루트 계정 + CloudWatch만 허용 | ✅ |
| 변경 이력 관리 | git 커밋 이력 | ✅ |
| EBS 전체 암호화 강제 | `aws_ebs_encryption_by_default = true` | ✅ |

### 현재 키 정책의 한계 (추후 개선 필요)

현재는 루트 계정에 `kms:*` 전체 권한을 부여하고 있습니다.
운영 환경 전환 시 역할별로 분리 필요:

| 역할 | 권한 |
|------|------|
| 보안 관리자 | `kms:Create*`, `kms:Delete*`, `kms:Put*` |
| 개발자 | `kms:Describe*`, `kms:List*` (조회만) |
| 서비스 Role | `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey*` |

---

## 4. Secrets Manager 개요

### KMS vs Secrets Manager 역할 구분

```
KMS                          Secrets Manager
────────────────────         ──────────────────────
"자물쇠 제조" 역할            "금고" 역할
키 자체는 AWS HSM 내부에      실제 비밀값(DB 비번, JWT 등)
저장, 외부 노출 없음           이 저장됨 → KMS로 금고를 잠금
```

### 현재 프로젝트 시크릿 목록

| 시크릿 이름 | 용도 | 생성 방법 | KMS 암호화 |
|------------|------|---------|-----------|
| `hospital/database-url` | PostgreSQL 연결 문자열 | CLI | `alias/aws-kms-sm-01` |
| `hospital/jwt-secret` | JWT 토큰 서명 키 | CLI (openssl rand -hex 64) | `alias/aws-kms-sm-01` |
| `hospital/api-key` | API 인증 키 | CLI (openssl rand -hex 32) | `alias/aws-kms-sm-01` |

### 시크릿이 앱에 주입되는 흐름

```
Secrets Manager (hospital/*)
        ↓
ECS Task Execution Role (secretsmanager:GetSecretValue 권한)
        ↓
ECS 컨테이너 시작 시 환경변수로 자동 주입 (valueFrom)
        ↓
FastAPI: os.getenv("DATABASE_URL"), os.getenv("JWT_SECRET")
```

---

## 5. Terraform에서 시크릿 관련 규칙

### ❌ 절대 하면 안 되는 것

```hcl
# Terraform으로 시크릿 값 직접 생성 금지
# → state 파일에 평문으로 저장됨
resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = "postgresql://user:password@host/db"  # 절대 금지
}
```

### ✅ 올바른 방법

**1. 시크릿 값은 CLI로만 생성**
```bash
aws secretsmanager create-secret \
  --name "hospital/my-secret" \
  --secret-string "$(openssl rand -hex 32)" \
  --kms-key-id alias/aws-kms-sm-01 \
  --region ap-south-2
```

**2. Terraform에서는 data source로만 참조**
```hcl
data "aws_secretsmanager_secret" "my_secret" {
  name = "hospital/my-secret"
}
```

**3. ECS Task에 주입 시 valueFrom 사용**
```hcl
secrets = [
  {
    name      = "MY_SECRET"
    valueFrom = data.aws_secretsmanager_secret.my_secret.arn
  }
]
```

**4. IAM 권한은 특정 ARN만 허용**
```hcl
# ❌ 잘못된 예 - 전체 허용
Resource = ["*"]

# ✅ 올바른 예 - 필요한 시크릿만 허용
Resource = [
  data.aws_secretsmanager_secret.my_secret.arn
]
```

### Terraform의 역할 요약

| 항목 | Terraform | CLI |
|------|-----------|-----|
| 비밀값 저장 | ❌ 절대 안 됨 | ✅ |
| 시크릿 위치(ARN) 참조 | ✅ 안전 | - |
| IAM 접근 권한 설정 | ✅ 권장 | - |

---

## 6. 시크릿 네이밍 규칙

```
hospital/<용도>

hospital/database-url
hospital/jwt-secret
hospital/api-key
```

---

## 7. 시크릿 생성 시 필수 옵션

| 옵션 | 값 | 이유 |
|------|-----|------|
| `--kms-key-id` | `alias/aws-kms-sm-01` | Secrets Manager 전용 KMS 키로 암호화 |
| `--region` | `ap-south-2` | 리전 명시 |
| `--secret-string` | `openssl rand` 사용 | 랜덤 생성, 직접 입력 금지 |

---

## 8. ISMS-P 준수 현황 (Secrets Manager)

| 항목 | 현재 상태 | 평가 |
|------|---------|------|
| 비밀값 암호화 보관 | KMS CMK(`aws-kms-sm-01`)로 암호화 | ✅ |
| 접근 최소화 | ECS Task Role만 3개 ARN에 한정 허용 | ✅ |
| 코드 내 비밀값 금지 | 코드에 하드코딩 없음, 환경변수로만 참조 | ✅ |
| 접근 통제 | IAM Role 기반 제어 | ✅ |
| Terraform state 노출 방지 | CLI 생성으로 state에 비밀값 없음 | ✅ |
| 시크릿 자동 로테이션 | 미설정 | ❌ 운영 전 필요 |

---

## 9. 추후 운영 전환 시 해야 할 것

1. **시크릿 자동 로테이션 설정** (ISMS-P 2.7.1)
   - `aws_secretsmanager_secret_rotation` 리소스 추가
   - 90일마다 DB 비밀번호 자동 교체

2. **KMS 키 정책 역할별 분리**
   - 루트 계정 전체 권한 → 역할별 최소 권한

3. **앱 코드 기본값 제거**
   ```python
   # 현재 (위험)
   JWT_SECRET = os.getenv("JWT_SECRET", "changeme")

   # 변경 필요
   JWT_SECRET = os.getenv("JWT_SECRET")
   if not JWT_SECRET:
       raise RuntimeError("JWT_SECRET is not set")
   ```

4. **Terraform Cloud Auto Apply 비활성화**
   - IAM 변경 시 반드시 보안 담당자 수동 승인 후 apply

---

## 10. 체크리스트

```
□ secret_string 또는 비밀값이 .tf 파일에 없는가?
□ KMS 키(alias/aws-kms-sm-01)로 암호화했는가?
□ IAM 권한이 필요한 ARN만 허용하는가?
□ 시크릿 이름이 hospital/* 형식인가?
□ Terraform state에 비밀값이 없는가?
     → terraform show | grep secret 으로 확인
```
