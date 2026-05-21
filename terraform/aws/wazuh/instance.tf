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
    Statement = [
      {
        Sid    = "AnsibleSSM"
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
      },
      {
        Sid    = "WazuhLogStorage"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*"
        ]
      },
      {
        Sid    = "KMSForS3"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = data.aws_kms_key.s3.arn
      },
      {
        Sid    = "CloudWatchLogsRead"
        Effect = "Allow"
        Action = [
          "logs:GetLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups"
        ]
        Resource = [
          "arn:aws:logs:ap-south-2:*:log-group:/aws/rds/cluster/aws-aurora-01/postgresql",
          "arn:aws:logs:ap-south-2:*:log-group:/aws/rds/cluster/aws-aurora-01/postgresql:*"
        ]
      }
    ]
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



