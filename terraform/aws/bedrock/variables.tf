variable "aws_region" {
  description = "AWS 기본 리전"
  type        = string
  default     = "ap-south-2"
}

variable "bedrock_region" {
  description = "Bedrock Knowledge Base 리전 (ap-south-2 미지원 → us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "admin_email" {
  description = "월간 리포트 수신 관리자 이메일"
  type        = string
  default     = "admin@example.com"
}

variable "alert_email" {
  description = "이상 지표 알림 수신 이메일"
  type        = string
  default     = "admin@example.com"
}

variable "annual_budget_krw" {
  description = "연간 인프라 예산 (원)"
  type        = number
  default     = 30000000
}

variable "gcp_billing_table_name" {
  description = "GCP 빌링 내보내기가 생성한 BigQuery 테이블명"
  type        = string
  default     = "gcp_billing_export_v1_011034_3337E0_C3B9BF"
}
