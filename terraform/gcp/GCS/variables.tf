variable "project_id" {
  description = "GCP 프로젝트 ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP 리전"
  type        = string
  default     = "asia-northeast3"
}

variable "cloud_sql_instance_name" {
  description = "Cloud SQL 인스턴스 이름"
  type        = string
  default     = "gcp-cloud-sql"
}
