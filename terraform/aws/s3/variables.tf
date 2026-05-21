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
