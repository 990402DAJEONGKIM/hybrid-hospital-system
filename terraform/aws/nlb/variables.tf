variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "base_domain" {
  description = "베이스 도메인"
  type        = string
  default     = "mzclinic.cloud"
}

variable "nlb_ip_2a" {
  description = "Internal NLB 고정 사설 IP (ap-south-2a, 10.0.11.0/24)"
  type        = string
  default     = "10.0.11.10"
}

variable "nlb_ip_2b" {
  description = "Internal NLB 고정 사설 IP (ap-south-2b, 10.0.12.0/24)"
  type        = string
  default     = "10.0.12.10"
}

variable "nlb_ip_2c" {
  description = "Internal NLB 고정 사설 IP (ap-south-2c, 10.0.13.0/24)"
  type        = string
  default     = "10.0.13.10"
}
