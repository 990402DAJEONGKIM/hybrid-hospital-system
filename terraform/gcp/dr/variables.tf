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

# ── 헬스체크 / 모니터 ──────────────────────────────────────────────────────────

variable "proxy_service_account_email" {
  description = <<-EOT
    DR failover 모니터 스크립트를 실행할 VM의 서비스 계정 이메일.
    별도 모니터 VM 없이 기존 프록시 VM(gcp-rds-proxy-01)의 SA를 사용합니다.
  EOT
  type    = string
  default = "tc-st1-account@gcp-project-496802.iam.gserviceaccount.com"
}

variable "aws_healthcheck_url" {
  description = <<-EOT
    AWS 메인 예약 서비스 health check URL.
    enable_monitor = true 일 때만 실제로 사용됩니다.
  EOT
  type    = string
  default = "http://localhost/health"
}

variable "healthcheck_interval_seconds" {
  description = "모니터링 주기 (초)"
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

# ── DR 앱 인프라 ───────────────────────────────────────────────────────────────

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

variable "dr_source_image" {
  description = "DR 앱/모니터 VM에 사용할 OS 이미지. 운영에서는 검증된 custom image 사용 권장"
  type        = string
  default     = "debian-cloud/debian-12"
}

# ── DNS ────────────────────────────────────────────────────────────────────────

variable "dns_managed_zone" {
  description = <<-EOT
    Cloud DNS managed zone 이름.
    enable_monitor = true 일 때만 실제로 사용됩니다.
    Terraform Cloud 워크스페이스 변수에서 실제 zone 이름으로 설정하세요.
  EOT
  type    = string
  default = ""
}

variable "dns_record_name" {
  description = <<-EOT
    전환할 FQDN. 끝에 점 포함. 예: booking.example.com.
    enable_monitor = true 일 때만 실제로 사용됩니다.
  EOT
  type    = string
  default = ""
}

variable "dns_record_type" {
  description = "전환할 DNS 레코드 타입. AWS 복귀 대상이 ALB면 CNAME 서브도메인 권장"
  type        = string
  default     = "A"
}

variable "dns_ttl" {
  description = "DNS TTL (초)"
  type        = number
  default     = 30
}

variable "aws_dns_rrdatas" {
  description = <<-EOT
    AWS 정상 상태 레코드 값. 예: ["aws-alb.example.com."] 또는 ["1.2.3.4"]
    enable_monitor = true 일 때만 실제로 사용됩니다.
  EOT
  type    = list(string)
  default = []
}

# ── Secret Manager ─────────────────────────────────────────────────────────────

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

# ── 기타 ───────────────────────────────────────────────────────────────────────

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
variable "cookie_secure" {
  description = "COOKIE_SECURE 환경변수. HTTPS 적용 전 false, 적용 후 true로 변경"
  type        = bool
  default     = false
}

# slack webhook url 추가 - 260602 김강환
variable "slack_webhook_url" {
  description = "Slack Webhook URL"
  type        = string
  sensitive   = true
}