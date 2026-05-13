data "aws_vpc" "aws-vpc-01" {
  tags = { Name = "aws-vpc-01" }
}

data "aws_subnet" "aws-app-sub-2a" {
  tags = { Name = "aws-app-sub-2a" }
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

output "wazuh_private_ip" {
  value = aws_instance.aws-wazuh-01.private_ip
}
