variable "project_id" {
  description = "GCP 프로젝트 ID"
  type        = string
}

variable "region" {
  description = "GCP 리전"
  type        = string
  default     = "asia-northeast3"   # 서울
}

variable "vpc_name" {
  description = "연결할 VPC 이름 (gcp-vpc workspace apply 후 확인)"
  type        = string
  default     = "GCP-VPC"
}
