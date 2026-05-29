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
  description = "GCP VPC 이름"
  type        = string
  default     = "gcp-vpc"
}

variable "subnet" {
  description = "GCP 서브넷 이름"
  type        = string
  default     = "gcp-subnet"
}

variable "cloud_sql_instance" {
  description = "DR 앱이 접속할 Cloud SQL 인스턴스명"
  type        = string
  default     = "gcp-cloud-sql"
}

variable "database_name" {
  description = "Cloud SQL 데이터베이스명"
  type        = string
  default     = "hospital"
}

variable "database_user" {
  description = "Cloud SQL 앱 유저"
  type        = string
  default     = "hospital_app"
}

variable "aws_healthcheck_url" {
  description = "AWS 메인 예약 서비스 health check URL"
  type        = string
}

variable "healthcheck_interval_seconds" {
  description = "모니터링 주기"
  type        = number
  default     = 30
}

variable "failure_threshold" {
  description = "연속 실패 몇 회부터 GCP DR로 전환할지"
  type        = number
  default     = 3
}

variable "recovery_threshold" {
  description = "연속 성공 몇 회부터 AWS로 복귀할지"
  type        = number
  default     = 5
}

variable "initial_dr_capacity" {
  description = "평상시 DR 앱 MIG VM 수. 자동 전환 전에는 0 권장"
  type        = number
  default     = 0
}

variable "dr_machine_type" {
  description = "DR 앱 VM machine type"
  type        = string
  default     = "e2-small"
}

variable "monitor_machine_type" {
  description = "AWS healthcheck 모니터 VM machine type"
  type        = string
  default     = "e2-micro"
}

variable "dr_source_image" {
  description = "DR 앱/모니터 VM에 사용할 OS 이미지. 운영에서는 검증된 custom image 사용 권장"
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "dns_managed_zone" {
  description = "Cloud DNS managed zone 이름"
  type        = string
}

variable "dns_record_name" {
  description = "전환할 FQDN. 끝에 점 포함 예: booking.example.com."
  type        = string
}

variable "dns_record_type" {
  description = "전환할 DNS 레코드 타입. AWS 복귀 대상이 ALB면 CNAME 서브도메인 권장"
  type        = string
  default     = "A"
}

variable "dns_ttl" {
  description = "DNS TTL"
  type        = number
  default     = 30
}

variable "aws_dns_rrdatas" {
  description = "AWS 정상 상태 레코드 값. 예: [\"aws-alb.example.com.\"] 또는 [\"1.2.3.4\"]"
  type        = list(string)
}

variable "db_password_secret_name" {
  description = "Cloud SQL 앱 유저 비밀번호가 저장된 Secret Manager secret 이름"
  type        = string
  default     = "gcp-cloud-sql-app-password"
}

variable "jwt_secret_name" {
  description = "DR 앱 JWT_SECRET이 저장된 Secret Manager secret 이름"
  type        = string
  default     = "gcp-dr-jwt-secret"
}

variable "api_key_secret_name" {
  description = "NGINX가 FastAPI로 주입할 X-API-Key가 저장된 Secret Manager secret 이름"
  type        = string
  default     = "gcp-dr-api-key"
}

variable "allowed_origins" {
  description = "DR 앱 CORS 허용 origin 목록. 비우면 dns_record_name 기반 http origin을 사용"
  type        = list(string)
  default     = []
}

variable "enable_ops_agent" {
  description = "VM에 Google Cloud Ops Agent를 설치해 system 로그를 Cloud Logging으로 전송"
  type        = bool
  default     = true
}

variable "failover_mode" {
  description = "automatic이면 DNS/MIG 자동 전환, manual이면 장애/복구 감지만 로그로 남김"
  type        = string
  default     = "manual"

  validation {
    condition     = contains(["manual", "automatic"], var.failover_mode)
    error_message = "failover_mode는 manual 또는 automatic이어야 합니다."
  }
}
