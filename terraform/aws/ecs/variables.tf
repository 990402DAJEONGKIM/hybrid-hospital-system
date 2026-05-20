variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
  default     = "vpc-032134a80cdaa051e"
}

# ── ECS EC2 설정 ─────────────────────────────────────────
variable "ec2_instance_type" {
  description = "ECS EC2 인스턴스 타입"
  type        = string
  default     = "t3.large"
}

variable "ec2_key_name" {
  description = "EC2 키페어 이름 (없으면 SSM Session Manager로만 접속)"
  type        = string
  default     = ""
}

variable "asg_min_size" {
  description = "ASG 최소 EC2 수 (3AZ × 1)"
  type        = number
  default     = 3
}

variable "asg_max_size" {
  description = "ASG 최대 EC2 수 (트래픽 급증 시 최대)"
  type        = number
  default     = 9
}

variable "asg_desired_size" {
  description = "ASG 초기 EC2 수"
  type        = number
  default     = 3
}

# ── Wazuh ───────────────────────────────────────────────
variable "wazuh_server_ip" {
  description = "Wazuh 서버 IP (에이전트가 연결할 주소, 미설정 시 설치 건너뜀)"
  type        = string
  default     = ""
}

# ── ALB Target Group ARN (ECS Service 연결) ───────────────
# ALB 모듈 apply 후 입력. 비어있으면 서비스 생성 건너뜀
variable "patient_tg_arn" {
  description = "환자 포털 ALB Target Group ARN (TC-ALB apply 후 입력)"
  type        = string
  default     = ""
}

variable "staff_tg_arn" {
  description = "의료진 포털 ALB Target Group ARN (TC-ALB apply 후 입력)"
  type        = string
  default     = ""
}

# ── ALLOWED_HOSTS (FastAPI TrustedHost) ──────────────────
variable "patient_allowed_hosts" {
  description = "환자 포털 도메인 (NGINX → FastAPI 프록시 Host 헤더)"
  type        = string
  default     = "localhost,127.0.0.1"
}

variable "staff_allowed_hosts" {
  description = "의료진 포털 도메인"
  type        = string
  default     = "localhost,127.0.0.1"
}
