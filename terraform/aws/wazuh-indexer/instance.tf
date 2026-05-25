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

resource "aws_iam_role_policy_attachment" "aws-wazuh-indexer-cloudwatch" {
  role       = aws_iam_role.aws-wazuh-indexer-role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "aws-wazuh-indexer-s3" {
  name = "aws-wazuh-indexer-s3-ssm"
  role = aws_iam_role.aws-wazuh-indexer-role.id

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
        Sid    = "WazuhSnapshotStorage"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*"
        ]
      },
      {
      Sid    = "WazuhSnapshotKMS"
      Effect = "Allow"
      Action = [
        "kms:GenerateDataKey",
        "kms:Decrypt"
      ]
      Resource = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
      }
    ]
  })
}
resource "aws_iam_instance_profile" "aws-wazuh-indexer-profile" {
  name = "aws-wazuh-indexer-profile"
  role = aws_iam_role.aws-wazuh-indexer-role.name
}



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

