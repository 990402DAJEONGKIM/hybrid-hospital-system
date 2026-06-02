#variables.tf
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

variable "grafana_admin_password" {
  description = "Grafana admin 비밀번호 — TFC sensitive 변수로 관리"
  type        = string
  sensitive   = true
}

variable "onprem_ip" {
  description = "온프레미스 서버 IP (Prometheus scrape용)"
  type        = string
}





variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID (ap-south-2) — ubuntu-jammy-22.04-amd64-server-20260521, Canonical 공식. 새 버전 출시 시 수동 업데이트 필요"
  type        = string
  default     = "ami-0eab39170eb2844c5"
}
