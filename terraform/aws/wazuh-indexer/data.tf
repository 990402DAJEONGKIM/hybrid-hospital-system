#data.tf
data "aws_vpc" "aws-vpc-01" {
  tags = { Name = "aws-vpc-01" }
}

data "aws_subnet" "aws-app-sub-2c" {
  tags = { Name = "aws-app-sub-2c" }
}

data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
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

data "terraform_remote_state" "wazuh2" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-wazuh2"
    }
  }
}

output "indexer_instance_id" {
  value = aws_instance.aws-wazuh-indexer.id
}