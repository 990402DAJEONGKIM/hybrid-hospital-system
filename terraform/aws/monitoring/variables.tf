variable "aws_region" {
  default = "ap-south-2"
}

variable "instance_type" {
  description = "모니터링 EC2 인스턴스 타입"
  type        = string
  default     = "t3.medium"
}

variable "base_domain" {
  description = "베이스 도메인"
  type        = string
  default     = "mzclinic.cloud"
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID (ap-south-2)"
  type        = string
  default     = "ami-0eab39170eb2844c5"
}
