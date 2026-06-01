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

variable "rds_ip" {
  description = "AWS RDS Private IP"
  type        = string
  default     = "10.0.21.124"
}

variable "rds_port" {
  description = "AWS RDS 포트"
  type        = number
  default     = 5432
}

variable "proxy_count" {
  description = "프록시 인스턴스 수 (0=삭제, 1=생성)"
  type        = number
  default     = 1
}

variable "cloud_sql_instance" {
  description = "Cloud SQL 인스턴스 이름"
  type        = string
  default     = "gcp-cloud-sql"
}

variable "wazuh_manager_ip" {
  description = "Wazuh Manager Private IP"
  type        = string
}