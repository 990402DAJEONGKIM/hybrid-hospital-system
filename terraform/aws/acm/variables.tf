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

variable "wazuh_subdomain" {
  description = "Wazuh 대시보드 서브도메인 prefix"
  type        = string
  default     = "wazuh"
}

# 2026-06-02 Grafana 서브도메인 추가 - 김강환
variable "grafana_subdomain" {
  description = "Grafana 대시보드 서브도메인 prefix"
  type        = string
  default     = "grafana"
}

# admin_subdomain 삭제 — admin.mzclinic.cloud 제거, staff로 통합
# variable "admin_subdomain" {
#   description = "관리자 포털 서브도메인 prefix"
#   type        = string
#   default     = "admin"
# }