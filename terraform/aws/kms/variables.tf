variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "aws_account_id" {
  description = "AWS 계정 ID (KMS 키 정책 구성용)"
  type        = string
}

# KMS 키 자동 교체 주기 (ISMS-P 2.7.1: 1년 이내 주기적 교체)
variable "key_rotation_period_days" {
  description = "KMS 키 자동 교체 주기 (일). ISMS-P 2.7.1 기준 365일 이내"
  type        = number
  default     = 365
}

# 키 삭제 대기 기간 (AWS 최소 7일, 운영환경 권장 30일)
variable "deletion_window_days" {
  description = "KMS 키 삭제 대기 기간 (일). 최소 7, 최대 30"
  type        = number
  default     = 30
}
