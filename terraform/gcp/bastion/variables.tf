variable "project_id" {
  description = "GCP 프로젝트 ID"
  type        = string
  default     = "gcp-project-496802"
}

variable "region" {
  description = "GCP 리전"
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "GCP 존"
  type        = string
  default     = "asia-northeast3-a"
}

variable "network" {
  description = "GCP VPC 네트워크 이름"
  type        = string
  default     = "gcp-vpc"
}

variable "subnet" {
  description = "GCP 서브넷 이름"
  type        = string
  default     = "gcp-subnet"
}

variable "bastion_count" {
  description = "베스천 인스턴스 수 (0=삭제, 1=생성)"
  type        = number
  default     = 1
}
