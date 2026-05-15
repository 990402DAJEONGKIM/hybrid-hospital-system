variable "aws_region" {
  default = "ap-south-2"
}

variable "slack_webhook_url" {
  sensitive = true
}
variable "wazuh_cluster_key" {
  sensitive = true
}
variable "wazuh_master_ip" {
  description = "Wazuh 서버1 프라이빗 IP"
  type        = string
}
variable "wazuh_admin_password" {
  sensitive = true
  
}