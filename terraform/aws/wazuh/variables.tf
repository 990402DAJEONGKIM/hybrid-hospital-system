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