variable "aws_region" {
  description = "AWS 뭄바이 리전"
  type        = string
  default     = "ap-south-1"
}


variable "vpc_cidr" {
  description = "뭄바이 VPC CIDR"
  type        = string
  default     = "10.1.0.0/16"
}

variable "db_subnet_cidr_1a" {
  description = "DB 서브넷 CIDR (ap-south-1a)"
  type        = string
  default     = "10.1.21.0/24"
}

variable "db_subnet_cidr_1b" {
  description = "DB 서브넷 CIDR (ap-south-1b)"
  type        = string
  default     = "10.1.22.0/24"
}

variable "vpc_cidr" {
  description = "하이데라바드 VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}
