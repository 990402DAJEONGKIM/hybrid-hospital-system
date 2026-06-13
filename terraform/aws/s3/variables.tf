variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "wazuh_log_retention_days" {
  description = "Wazuh 로그 보존 기간 (일) — ISMS-P 2.9.1 최소 1년"
  type        = number
  default     = 365
}

variable "wazuh_log_glacier_days" {
  description = "Glacier 전환 기간 (일) — 보존 비용 절감"
  type        = number
  default     = 90
}

#260526 st1 추가
variable "db_dump_retention_days" {
  description = "DB 덤프 보존 기간 (일)"
  type        = number
  default     = 30
}

# by 김다정 2026-06-13 추가
variable "db_dump_expiration_days" {
  description = "DB 덤프 최종 삭제 기간 (일) — Glacier 전환 후 보존"
  type        = number
  default     = 365
}

# 추가: s3 백업 보존 기간 지정 - (20260530, by 김다정)
variable "github_backup_retention_days" {
  description = "GitHub 백업 보존 기간 (일) — source/, tfstate/"
  type        = number
  default     = 90
}

variable "github_backup_log_retention_days" {
  description = "GitHub 백업 증적 로그 보존 기간 (일) — ISMS-P 2.9.1"
  type        = number
  default     = 365
}


variable "flowlogs_retention_days" {
  description = "VPC Flow Log 보존 기간 (일) — REJECT만 저장"
  type        = number
  default     = 365
}

variable "waf_retention_days" {
  description = "WAF 로그 보존 기간 (일) — 이미 차단된 트래픽"
  type        = number
  default     = 90
}

variable "wazuh_db_backup_retention_days" {
  description = "Wazuh wodle DB 백업 보존 기간 (일) — 재생성 가능"
  type        = number
  default     = 7
}

variable "wazuh_snapshots_retention_days" {
  description = "Wazuh Indexer 스냅샷 보존 기간 (일) — alerts/에 원본 있음"
  type        = number
  default     = 30
}
