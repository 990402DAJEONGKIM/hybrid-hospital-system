variable "aws_region" {
  default = "ap-south-2"
}

variable "wazuh_admin_password" {
  sensitive = true
}

variable "ami_id" {
  description = "Wazuh Indexer Ubuntu 22.04 AMI ID (ap-south-2)"
  type        = string
  default     = "ami-0eab39170eb2844c5"
}

variable "indexer_private_ip" {
  description = "Wazuh Indexer 고정 Private IP"
  type        = string
}