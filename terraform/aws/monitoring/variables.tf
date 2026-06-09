variable "aws_region" {
  default = "ap-south-2"
}

variable "instance_type" {
  description = "모니터링 EC2 인스턴스 타입"
  type        = string
  default     = "t3.medium"
}

variable "base_domain" {
  description = "베이스 도메인"
  type        = string
  default     = "mzclinic.cloud"
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID (ap-south-2)"
  type        = string
  default     = "ami-0eab39170eb2844c5"
}

variable "monitoring_private_ip" {
  description = "monitoring EC2 고정 Private IP — TFC Variables에서 관리"
  type        = string
}

# #260609 박경수 — Keycloak + 통합 포털 추가 변수
variable "cloudflare_api_token" {
  description = "Cloudflare API token"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for mzclinic.cloud"
  type        = string
  sensitive   = true
}

variable "keycloak_db_password" {
  description = "Keycloak DB 초기 비밀번호 (이후 Secrets Manager rotation으로 관리)"
  type        = string
  sensitive   = true
}

variable "keycloak_admin_password" {
  description = "Keycloak 관리자 콘솔 비밀번호"
  type        = string
  sensitive   = true
}

variable "wazuh_private_ip" {
  description = "Wazuh Dashboard EC2 private IP"
  type        = string
  default     = "10.0.11.66"
}

variable "monitoring_domain" {
  description = "통합 모니터링 포털 도메인"
  type        = string
  default     = "monitoring.mzclinic.cloud"
}

variable "aurora_endpoint" {
  description = "Aurora 클러스터 엔드포인트"
  type        = string
  default     = "aws-aurora-01.cluster-cjsaws8mcmwn.ap-south-2.rds.amazonaws.com"
}

variable "aurora_sg_id" {
  description = "Aurora 보안그룹 ID"
  type        = string
  default     = "sg-09f6c3596fb691e55"
}
# #260609 박경수 end
