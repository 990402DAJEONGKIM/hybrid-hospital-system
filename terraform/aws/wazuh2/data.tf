#data.tf
data "aws_vpc" "aws-vpc-01" {
  tags = { Name = "aws-vpc-01" }
}
data "aws_subnet" "aws-app-sub-2b" {
  tags = { Name = "aws-app-sub-2b" }
}


data "terraform_remote_state" "wazuh" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-wazuh"
    }
  }
}
data "aws_security_group" "aws-wazuh-sg" {
  name = "aws-wazuh-sg"
}

output "wazuh_private_ip" {
  value = aws_instance.aws-wazuh-02.private_ip
  sensitive = true
}


output "wazuh_instance_id" {
  value = aws_instance.aws-wazuh-02.id
  sensitive = true
}
output "wazuh_instance_arn" {
  value = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.aws-wazuh-02.id}"
  sensitive = true
}

