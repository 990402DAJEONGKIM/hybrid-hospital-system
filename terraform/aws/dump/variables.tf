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

variable "rds_secret_arn" {
  description = "Secrets Manager — dump_user 비밀번호 ARN"
  type        = string
  sensitive   = true
}

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
  description = "dump_user 비밀번호 로테이션 주기 (일) — ISMS-P 2.5.4"
  type        = number
  default     = 7
}
