variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "vpc_id" {
  description = "Lambda를 배치할 VPC ID"
  type        = string
}

variable "rds_subnet_ids" {
  description = "Lambda 배치용 private subnet ID 목록"
  type        = list(string)
}

variable "rds_instance_id" {
  description = "RDS Aurora 인스턴스 ID"
  type        = string
  default     = "aws-aurora-01"
}

variable "rds_security_group_id" {
  description = "RDS 보안 그룹 ID"
  type        = string
}

# ─────────────────────────────────────────────────────────
# [현재 상태] dump Lambda가 dump_user 시크릿에 접근하기 위한 ARN.
#   TFC 워크스페이스 변수에 직접 입력해서 사용 중.
#
# [마이그레이션 후] TC-aws-secrets apply 완료 시:
#   1. 이 변수 제거
#   2. rotation.tf 의 tfe_outputs 블록 주석 해제
#   3. lambda.tf 의 var.rds_secret_arn → local.dump_user_secret_arn 으로 교체
# ─────────────────────────────────────────────────────────
# variable "rds_secret_arn" {
#   description = "Secrets Manager — dump_user 비밀번호 ARN (TC-aws-secrets 적용 전 임시 변수)"
#   type        = string
#   sensitive   = true
# }

variable "s3_bucket_name" {
  description = "덤프를 저장할 S3 버킷 이름 (TC-aws-S3에서 관리)"
  type        = string
  default     = "aws-k2p-storage-01"
}

variable "db_dump_schedule_cron" {
  description = "EventBridge cron 표현식 (UTC) — 기본값: KST 02:30"
  type        = string
  default     = "cron(30 17 * * ? *)"
}

variable "db_dump_lambda_memory" {
  description = "dump Lambda 메모리 (MB)"
  type        = number
  default     = 512
}

variable "db_dump_lambda_timeout" {
  description = "dump Lambda 타임아웃 (초)"
  type        = number
  default     = 600
}

variable "dump_user_rotation_days" {
  description = "dump_user 비밀번호 로테이션 주기 (일) — TC-aws-secrets 적용 후 해당 워크스페이스에서 관리"
  type        = number
  default     = 7
}

# ─────────────────────────────────────────────────────────
# [제거됨] api_user 관련 변수
#   api_user_secret_arn, api_user_rotation_days 는
#   TC-aws-secrets 워크스페이스에서 통합 관리.
#   dump 워크스페이스에서는 불필요하므로 제거.
# ─────────────────────────────────────────────────────────
