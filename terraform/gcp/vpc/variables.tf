variable "project_id" {
  description = "GCP 프로젝트 ID"
  type        = string
}

variable "region" {
  description = "GCP 리전"
  type        = string
  default     = "asia-northeast3"   # 서울
}

variable "aws_vpc_cidr" {
  description = "AWS VPC CIDR (pglogical 방화벽 허용 대역, RDS가 속한 VPC)"
  type        = string
  # 예: "10.0.0.0/16"
}
