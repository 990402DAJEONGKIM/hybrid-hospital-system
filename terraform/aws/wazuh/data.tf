#data.tf

data "aws_vpc" "aws-vpc-01" {
  tags = { Name = "aws-vpc-01" }
}

data "aws_subnet" "aws-app-sub-2a" {
  tags = { Name = "aws-app-sub-2a" }
}



data "aws_subnet" "aws-app-sub-2b" {
  tags = { Name = "aws-app-sub-2b" }
}

data "terraform_remote_state" "kms" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-KMS"
    }
  }
}

data "aws_caller_identity" "current" {}

output "wazuh_private_ip" {
  value = aws_instance.aws-wazuh-01.private_ip
  sensitive = true
}

output "wazuh_instance_id" {
  value = aws_instance.aws-wazuh-01.id
  sensitive = true
}
# wazuh_private_ip는 이미 있음

output "wazuh_instance_arn" {
  value = aws_instance.aws-wazuh-01.arn
  sensitive = true
}



