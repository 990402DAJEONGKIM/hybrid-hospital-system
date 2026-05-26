#instance.tf

resource "aws_key_pair" "aws-wazuh-key" {
  key_name   = "aws-wazuh-key"
  public_key = var.ssh_public_key

  tags = {
    Name  = "aws-wazuh-key"
    Owner = "st2"
  }
}

resource "aws_instance" "aws-wazuh-01" {
  ami                    = "ami-0eab39170eb2844c5"
  instance_type          = "t3.large"
  subnet_id              = data.aws_subnet.aws-app-sub-2a.id
  vpc_security_group_ids = [aws_security_group.aws-wazuh-sg.id]
  key_name               = aws_key_pair.aws-wazuh-key.key_name
  iam_instance_profile   = aws_iam_instance_profile.aws-wazuh-profile.name

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true 
  }

  tags = {
    Name  = "aws-wazuh-01"
    Owner = "st2"
  }
}



