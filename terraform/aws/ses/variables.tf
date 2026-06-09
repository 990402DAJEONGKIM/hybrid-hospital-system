variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "admin_email" {
  description = "월간 리포트 수신 관리자 이메일"
  type        = string
}

variable "alert_email" {
  description = "이상 지표 알림 수신 이메일"
  type        = string
}
