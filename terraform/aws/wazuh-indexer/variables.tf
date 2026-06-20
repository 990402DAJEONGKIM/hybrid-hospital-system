variable "aws_region" {
  default = "ap-south-2"
}

variable "wazuh_admin_password" {
  sensitive = true
}

variable "ami_id" {
  description = "Wazuh Indexer Golden Image"
  type        = string
  default     = "ami-065ef798ce818374e"
}

variable "indexer_private_ip" {
  description = "Wazuh Indexer 고정 Private IP"
  type        = string
}