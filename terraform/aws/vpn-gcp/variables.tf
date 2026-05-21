variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-2"
}

variable "gcp_vpn_ip" {
  description = "GCP Cloud VPN Gateway 외부 IP (TC-gcp-VPN-AWS output)"
  type        = string
}

variable "gcp_cidr" {
  description = "GCP VPC 서브넷 대역"
  type        = string
  default     = "10.10.1.0/24"
}

variable "tunnel1_psk" {
  description = "터널1 Pre-Shared Key (openssl rand -hex 32)"
  type        = string
  sensitive   = true
}

variable "tunnel2_psk" {
  description = "터널2 Pre-Shared Key (openssl rand -hex 32)"
  type        = string
  sensitive   = true
}

variable "gcp_psa_cidr" {
  description = "GCP Cloud SQL PSA 대역 (pglogical 복제용)"
  type        = string
  default     = "172.29.0.0/24"
}
