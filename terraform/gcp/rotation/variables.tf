variable "project_id" {
  description = "GCP 프로젝트 ID"
  type        = string
}

variable "region" {
  description = "GCP 리전"
  type        = string
  default     = "asia-northeast3"
}

variable "cloud_sql_instance_name" {
  description = "Cloud SQL 인스턴스 이름"
  type        = string
  default     = "gcp-cloud-sql"
}

variable "cloud_sql_private_ip" {
  description = "Cloud SQL Private IP"
  type        = string
  default     = "172.29.0.2"
}

variable "vpc_network" {
  description = "GCP VPC 네트워크 이름"
  type        = string
}

variable "vpc_subnet" {
  description = "Cloud Functions 배치용 서브넷 이름"
  type        = string
}

variable "rotation_schedule_cron" {
  description = "로테이션 Cloud Scheduler cron 표현식 (KST 기준)"
  type        = string
  default     = "0 3 */7 * *"   # 7일마다 KST 03:00
}

variable "aws_region" {
  description = "AWS 리전 (pglogical_repl RDS 비밀번호 변경용)"
  type        = string
  default     = "ap-south-2"
}

variable "rds_endpoint" {
  description = "RDS Aurora 엔드포인트"
  type        = string
  default     = "aws-aurora-01.cluster-cjsaws8mcmwn.ap-south-2.rds.amazonaws.com"
}

variable "postgres_initial_password" {
  description = "postgres 계정 초기 비밀번호 (최초 1회, 이후 자동 로테이션)"
  type        = string
  sensitive   = true
}
variable "aws_access_key_id" {
  description = "AWS Access Key ID (pglogical_repl RDS 비밀번호 변경용)"
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS Secret Access Key (pglogical_repl RDS 비밀번호 변경용)"
  type        = string
  sensitive   = true
}