# variables.tf

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

variable "ec2_ami_id" {
  description = "ECS-optimized AL2023 AMI (ap-south-2) | al2023-ami-ecs-hvm-2023.0.20260518-kernel-6.1-x86_64"
  type        = string
  default     = "ami-0546e40dc8a023937"
}

variable "ec2_key_name" {
  description = "EC2 키페어 이름 (없으면 SSM Session Manager로만 접속)"
  type        = string
  default     = ""
}

variable "asg_min_size" {
  description = "ASG 최소 EC2 수"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "ASG 최대 EC2 수"
  type        = number
  default     = 4
}

variable "asg_desired_size" {
  description = "ASG 초기 EC2 수"
  type        = number
  default     = 1
}

# ── Wazuh ───────────────────────────────────────────────
variable "wazuh_server_ip" {
  description = "Wazuh 서버 IP (에이전트가 연결할 주소, 미설정 시 설치 건너뜀)"
  type        = string
  default     = ""
}

# ── ALLOWED_HOSTS (FastAPI TrustedHost) ──────────────────
variable "patient_allowed_hosts" {
  description = "환자 포털 도메인 (NGINX → FastAPI 프록시 Host 헤더)"
  type        = string
  default     = "patient.mzclinic.cloud,localhost"
}

variable "staff_allowed_hosts" {
  description = "의료진 포털 도메인"
  type        = string
  default     = "staff.mzclinic.cloud,localhost"
}

# ── 알람 수신 이메일 ──────────────────────────────────────
variable "alert_email" {
  description = "CloudWatch 알람 수신 이메일 (rotation 실패 시 알림)"
  type        = string
}
