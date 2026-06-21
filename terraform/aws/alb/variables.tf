variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "base_domain" {
  description = "베이스 도메인"
  type        = string
  default     = "mzclinic.cloud"
}

variable "wazuh_manager_ip" {
  description = "Wazuh Manager Private IP"
  type        = string
}

variable "monitoring_private_ip" {
  description = "Monitoring EC2 고정 Private IP - Grafana TG attachment용"
  type        = string
}