variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

# by 김다정 20260604
variable "base_domain" {
  description = "베이스 도메인 (staff/admin host 매칭용)"
  type        = string
  default     = "mzclinic.cloud"
}

# 주석 처리: patient-alb 삭제로 불필요 by 김다정 20260604
# variable "patient_alb_name" {
#   description = "환자 포털 ALB 이름"
#   type        = string
#   default     = "aws-patient-alb"
# }

variable "waf_log_retention_days" {
  description = "WAF 로그 보존 기간 (일) — ISMS-P 2.9.1 최소 1년"
  type        = number
  default     = 365
}

variable "rate_limit_auth" {
  description = "로그인 엔드포인트 5분당 최대 요청 수 — ISMS-P 2.5.4 브루트포스 방어"
  type        = number
  default     = 100
}

variable "staff_alb_name" {
  description = "통합 병원 ALB 이름"
  type        = string
  default     = "aws-hospital-alb"
}

variable "staff_allowed_ips" {
  description = "의료진 포털 허용 공인 IP 목록 (CIDR) — 병원 공인 IP 확정 시 추가"
  type        = list(string)
  default     = ["218.235.89.82/32", "221.164.19.186/32",  "175.199.193.165/32"] #집에서 접속해보려고  "175.199.193.165/32" 추가했습니다. 260601 박경수.
}
