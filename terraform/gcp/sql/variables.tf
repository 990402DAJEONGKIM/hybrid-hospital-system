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
  default     = "gcp-vpc"
}

variable "activation_policy" {
  description = "Cloud SQL 인스턴스 상태 (ALWAYS=켜기, NEVER=끄기)"
  type        = string
  default     = "ALWAYS"
}
