#instance.tf

# EC2
resource "aws_instance" "aws-wazuh-indexer" {
  ami                    = "ami-0eab39170eb2844c5"
  instance_type          = "t3.xlarge"
  subnet_id              = data.aws_subnet.aws-app-sub-2c.id
  vpc_security_group_ids = [aws_security_group.aws-wazuh-indexer-sg.id]
  iam_instance_profile   = aws_iam_instance_profile.aws-wazuh-indexer-profile.name
  private_ip             = "10.0.13.83" 
  root_block_device {
    volume_size = 100
    volume_type = "gp3"

    tags = {
      Name  = "aws-wazuh-indexer-volume"
      Owner = "st2"
    }
  }
  tags = {
    Name  = "aws-wazuh-indexer"
    Owner = "st2"
  }


}

