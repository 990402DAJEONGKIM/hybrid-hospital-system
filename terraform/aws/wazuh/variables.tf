variable "aws_region" {
  default = "ap-south-2"
}

variable "slack_webhook_url" {
  sensitive = true
}
variable "wazuh_cluster_key" {
  sensitive = true
}
variable "ssh_public_key" {
  sensitive = true
}


variable "wazuh_indexer_ip" {
  description = "Wazuh Indexer Private IP"  # EIP → Private IP로 수정
  type        = string
}

variable "wazuh_01_private_ip" {
  description = "wazuh-01 고정 Private IP"
  type        = string
}