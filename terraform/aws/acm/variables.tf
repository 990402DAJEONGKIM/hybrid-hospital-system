variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "base_domain" {
  description = "베이스 도메인 — Route 53 Hosted Zone 조회 및 서브도메인 생성에 사용"
  type        = string
  default     = "mzclinic.cloud"
}

variable "patient_subdomain" {
  description = "환자 포털 서브도메인 prefix"
  type        = string
  default     = "patient"
}

variable "staff_subdomain" {
  description = "의료진 포털 서브도메인 prefix"
  type        = string
  default     = "staff"
}
