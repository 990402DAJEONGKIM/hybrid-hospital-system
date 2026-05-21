#instance.tf
data "aws_iam_instance_profile" "aws-wazuh-profile" {
  name = "aws-wazuh-instance-profile"
}

data "aws_key_pair" "aws-wazuh-key" {
  key_name = "aws-wazuh-key"
}

# EC2
resource "aws_instance" "aws-wazuh-02" {
  ami                    = "ami-0eab39170eb2844c5"
  instance_type          = "t3.large"
  subnet_id              = data.aws_subnet.aws-app-sub-2b.id
  vpc_security_group_ids = [data.aws_security_group.aws-wazuh-sg.id]
  key_name               = data.aws_key_pair.aws-wazuh-key.key_name
  iam_instance_profile   = data.aws_iam_instance_profile.aws-wazuh-profile.name

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = {
    Name  = "aws-wazuh-02"
    Owner = "st2"
  }
}


