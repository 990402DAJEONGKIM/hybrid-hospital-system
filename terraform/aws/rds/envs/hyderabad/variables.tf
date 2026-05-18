variable "aws_region" {
  description = "AWS 하이데라바드 리전"
  type        = string
  default     = "ap-south-2"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
  default     = "vpc-032134a80cdaa051e"
}

# DB 서브넷 ID — 콘솔 생성 후 채워넣기
variable "db_subnet_ids" {
  description = "DB 서브넷 ID 목록 (10.0.21~23.0/24)"
  type        = list(string)
  default     = []  # ["subnet-xxxx", "subnet-yyyy", "subnet-zzzz"]
}

# App 서브넷 CIDR (보안 그룹 Proxy inbound)
variable "app_subnet_cidrs" {
  description = "App 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "onprem_cidr" {
  description = "온프레미스 네트워크 CIDR (VPN)"
  type        = string
  default     = "172.30.1.0/24"
}

variable "db_name" {
  description = "초기 데이터베이스 이름"
  type        = string
  default     = "hospital"
}

variable "db_master_username" {
  description = "Aurora 마스터 유저"
  type        = string
  default     = "hospital_user"
}

variable "db_master_password" {
  description = "Aurora 마스터 패스워드 (민감 — tfvars 또는 환경변수로 주입)"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "Aurora 인스턴스 클래스"
  type        = string
  default     = "db.r6g.large"
}

variable "db_engine_version" {
  description = "Aurora PostgreSQL 엔진 버전"
  type        = string
  default     = "17.9"
}

variable "backup_retention_days" {
  description = "백업 보존 기간 (일)"
  type        = number
  default     = 7
}

variable "aws_account_id" {
  description = "AWS 계정 ID (Secrets Manager ARN 구성용)"
  type        = string
}

# bastion host 용 (by 김다정 2026.05.13)
# =========================================================================================
# bastion 서버의 켜짐(1)" 또는 "꺼짐(0)" 신호를 받아줄 변수를 선언.
variable "bastion_count" {
  description = "Bastion 서버 가동 여부 (0 또는 1)"
  type        = number
  default     = 0 # 기본적으로는 꺼진 상태 유지
}
# =========================================================================================