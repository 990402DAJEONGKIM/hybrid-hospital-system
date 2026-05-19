#instance.tf

# IAM Role
resource "aws_iam_role" "aws-wazuh-indexer-role" {
  name = "aws-wazuh-indexer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "aws-wazuh-indexer-role", Owner = "st2" }
}

resource "aws_iam_role_policy_attachment" "aws-wazuh-indexer-ssm" {
  role       = aws_iam_role.aws-wazuh-indexer-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "aws-wazuh-indexer-s3" {
  name = "aws-wazuh-indexer-s3-ssm"
  role = aws_iam_role.aws-wazuh-indexer-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:DeleteObject",
        "s3:GetBucketLocation"
      ]
      Resource = [
        "arn:aws:s3:::wazuh-ansible-ssm",
        "arn:aws:s3:::wazuh-ansible-ssm/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "aws-wazuh-indexer-profile" {
  name = "aws-wazuh-indexer-profile"
  role = aws_iam_role.aws-wazuh-indexer-role.name
}



# EC2
resource "aws_instance" "aws-wazuh-indexer" {
  ami                    = data.aws_ami.ubuntu_22_04.id
  instance_type          = "t3.xlarge"
  subnet_id              = data.aws_subnet.aws-app-sub-2a.id
  vpc_security_group_ids = [aws_security_group.aws-wazuh-indexer-sg.id]
  iam_instance_profile   = aws_iam_instance_profile.aws-wazuh-indexer-profile.name
  private_ip             = "10.0.11.83" 
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

# hosts.ini
resource "aws_s3_object" "aws-wazuh-indexer-hosts" {
  bucket = "wazuh-ansible-ssm"
  key    = "wazuh-indexer/hosts.ini"
  content = <<-EOT
    [wazuh-indexer]
    ${aws_instance.aws-wazuh-indexer.id}

    [wazuh-indexer:vars]
    ansible_connection=community.aws.aws_ssm
    ansible_aws_ssm_region=${var.aws_region}
    ansible_aws_ssm_bucket_name=wazuh-ansible-ssm
    ansible_aws_ssm_plugin_path=/usr/local/bin/session-manager-plugin
    ansible_aws_ssm_timeout=3600
    wazuh_manager1_ip=${data.terraform_remote_state.wazuh.outputs.wazuh_private_ip}
    wazuh_manager2_ip=${data.terraform_remote_state.wazuh2.outputs.wazuh_private_ip}
  EOT
}
