# =========================================================
# TC-aws-secrets — 변수 정의
# =========================================================

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "aws_account_id" {
  description = "AWS 계정 ID"
  type        = string
  default     = "476293896981"
}

variable "environment" {
  description = "배포 환경"
  type        = string
  default     = "prod"
}

variable "vpc_id" {
  description = "Rotation Lambda를 배치할 VPC ID"
  type        = string
}

variable "rds_subnet_ids" {
  description = "Rotation Lambda 배치용 private subnet ID 목록"
  type        = list(string)
}

variable "rds_security_group_id" {
  description = "RDS 보안 그룹 ID (Rotation Lambda SG를 인바운드 허용 대상에 추가)"
  type        = string
}

# ── 로테이션 주기 ────────────────────────────────────────
variable "hospital_user_rotation_days" {
  description = "hospital_user 비밀번호 로테이션 주기 (일) — ISMS-P 2.5.4 / Vault DB config 연동"
  type        = number
  default     = 7
}

variable "dump_user_rotation_days" {
  description = "dump_user 비밀번호 로테이션 주기 (일) — ISMS-P 2.5.4"
  type        = number
  default     = 7
}

variable "api_user_rotation_days" {
  description = "api_user 비밀번호 로테이션 주기 (일) — ISMS-P 2.5.4"
  type        = number
  default     = 90
}
