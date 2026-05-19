variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

# ── 도메인 설정 ──────────────────────────────────────────────
# 예) patient_domain = "patient.kimyipark.com"
#     staff_domain   = "staff.kimyipark.com"
# Route 53에 해당 도메인의 Hosted Zone이 등록되어 있어야 DNS 검증 가능

variable "patient_domain" {
  description = "환자 포털 도메인 (Public ALB에 연결)"
  type        = string
}

variable "staff_domain" {
  description = "의료진 포털 도메인 (Internal ALB에 연결, VPN 전용)"
  type        = string
}

variable "route53_zone_id" {
  description = "Route 53 Hosted Zone ID (DNS 검증 레코드 자동 생성용)"
  type        = string
}
