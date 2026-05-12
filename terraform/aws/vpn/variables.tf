##############################################################
# variables.tf
##############################################################

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "onprem_public_ip" {
  description = "온프레미스 라우터 공인 IP (Customer Gateway)"
  type        = string
  default     = "175.199.193.165"
}

variable "onprem_cidr" {
  description = "온프레미스 사설 네트워크 대역"
  type        = string
  default     = "172.30.1.0/24"
}
