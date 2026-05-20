variable "project_id" {
  description = "GCP 프로젝트 ID"
  type        = string
  default     = "gcp-project-496802"
}

variable "region" {
  description = "GCP 리전"
  type        = string
  default     = "asia-south1"
}

variable "aws_tunnel1_ip" {
  description = "AWS VPN 터널1 외부 IP (TC-aws-VPN-GCP output)"
  type        = string
}

variable "aws_tunnel2_ip" {
  description = "AWS VPN 터널2 외부 IP (TC-aws-VPN-GCP output)"
  type        = string
}

variable "aws_tunnel1_psk" {
  description = "AWS VPN 터널1 Pre-Shared Key (TC-aws-VPN-GCP과 동일값)"
  type        = string
  sensitive   = true
}

variable "aws_tunnel2_psk" {
  description = "AWS VPN 터널2 Pre-Shared Key (TC-aws-VPN-GCP과 동일값)"
  type        = string
  sensitive   = true
}

variable "aws_db_cidrs" {
  description = "AWS DB 서브넷 대역 (pglogical 소스)"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
}

variable "gcp_network" {
  description = "GCP VPC 네트워크 이름"
  type        = string
  default     = "gcp-vpc"
}

variable "gcp_subnet" {
  description = "GCP 서브넷 이름"
  type        = string
  default     = "gcp-subnet"
}
