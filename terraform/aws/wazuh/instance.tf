#instance.tf

# IAM Role
resource "aws_iam_role" "aws-wazuh-ssm-role" {
  name = "aws-wazuh-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "aws-wazuh-ssm-role", Owner = "st2" }
}

# CloudWatch Agent 권한
resource "aws_iam_role_policy_attachment" "aws-wazuh-cloudwatch" {
  role       = aws_iam_role.aws-wazuh-ssm-role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}


# SSM 권한
resource "aws_iam_role_policy_attachment" "aws-wazuh-ssm" {
  role       = aws_iam_role.aws-wazuh-ssm-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# S3 권한 (Ansible SSM connection용)
resource "aws_iam_role_policy" "aws-wazuh-s3" {
  name = "aws-wazuh-s3"
  role = aws_iam_role.aws-wazuh-ssm-role.id

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
        "arn:aws:s3:::wazuh-ansible-ssm/*",
        "arn:aws:s3:::aws-wazuh-storage",
        "arn:aws:s3:::aws-wazuh-storage/*"
      ]
    }]
  })
}

# EC2에 IAM Role 연결하는 다리
resource "aws_iam_instance_profile" "aws-wazuh-profile" {
  name = "aws-wazuh-instance-profile"
  role = aws_iam_role.aws-wazuh-ssm-role.name
}

resource "aws_key_pair" "aws-wazuh-key" {
  key_name   = "aws-wazuh-key"
  public_key = var.ssh_public_key

  tags = {
    Name  = "aws-wazuh-key"
    Owner = "st2"
  }
}

resource "aws_instance" "aws-wazuh-01" {
  ami                    = data.aws_ami.ubuntu_22_04.id
  instance_type          = "t3.large"
  subnet_id              = data.aws_subnet.aws-app-sub-2a.id
  vpc_security_group_ids = [aws_security_group.aws-wazuh-sg.id]
  key_name               = aws_key_pair.aws-wazuh-key.key_name
  iam_instance_profile   = aws_iam_instance_profile.aws-wazuh-profile.name

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = {
    Name  = "aws-wazuh-01"
    Owner = "st2"
  }
}

# hosts.ini 자동 생성
resource "aws_s3_object" "aws-ansible-hosts" {
  bucket  = "wazuh-ansible-ssm"
  key = "wazuh1/hosts.ini"
  content = <<-EOT
    [wazuh]
    ${aws_instance.aws-wazuh-01.id}

    [wazuh:vars]
    ansible_connection=community.aws.aws_ssm
    ansible_aws_ssm_region=${var.aws_region}
    ansible_aws_ssm_bucket_name=wazuh-ansible-ssm
    ansible_aws_ssm_plugin_path=/usr/local/bin/session-manager-plugin
    ansible_aws_ssm_timeout=3600
    wazuh_node_name=wazuh-01
    wazuh_node_type=master
    wazuh_master_ip=${aws_instance.aws-wazuh-01.private_ip}
    wazuh_cluster_key=${var.wazuh_cluster_key}
    slack_webhook_url=${var.slack_webhook_url}
    wazuh_indexer_ip=${var.wazuh_indexer_ip}
    wazuh_cert_name=wazuh-1
  EOT
}
