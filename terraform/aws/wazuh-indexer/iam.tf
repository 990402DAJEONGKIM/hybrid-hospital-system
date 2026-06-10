# iam.tf - 인덱서 전용
# 추가 260610 김강환 (복원)

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

resource "aws_iam_role_policy" "aws-wazuh-indexer-s3-policy" {
  name = "aws-wazuh-indexer-s3-policy"
  role = aws_iam_role.aws-wazuh-indexer-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AnsibleSSM"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket",
                  "s3:DeleteObject", "s3:GetBucketLocation"]
        Resource = [
          "arn:aws:s3:::wazuh-ansible-ssm",
          "arn:aws:s3:::wazuh-ansible-ssm/*"
        ]
      },
      {
        Sid    = "WazuhLogStorage"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*"
        ]
      },
      {
        Sid      = "KMSForS3"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Sid    = "ReadIndexerSecret"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:aws-wazuh-indexer-credentials-*"
        ]
      },
      {
        Sid      = "DecryptIndexerSecretViaSM"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.terraform_remote_state.kms.outputs.secretsmanager_kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "aws-wazuh-indexer-profile" {
  name = "aws-wazuh-indexer-profile"
  role = aws_iam_role.aws-wazuh-indexer-role.name
}



# 인덱서 자동복구 Lambda IAM
# 추가 260610 김강환
resource "aws_iam_role" "aws-wazuh-indexer-recovery-role" {
  name = "aws-wazuh-indexer-recovery-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = { Name = "aws-wazuh-indexer-recovery-role", Owner = "st2" }
}

# 실행 로그 (증적용)
resource "aws_iam_role_policy_attachment" "aws-wazuh-indexer-recovery-basic" {
  role       = aws_iam_role.aws-wazuh-indexer-recovery-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "aws-wazuh-indexer-recovery-policy" {
  name = "aws-wazuh-indexer-recovery-policy"
  role = aws_iam_role.aws-wazuh-indexer-recovery-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # EC2 재구축 + EBS 분리/부착 (시크릿 권한 일절 없음)
        Sid    = "EC2AndEBSRecovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeVolumes",
          "ec2:DescribeImages",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:CreateTags",
          "ec2:AttachVolume",
          "ec2:DetachVolume"
        ]
        Resource = "*"
      },
      {
        # 새 인스턴스에 마운트/서비스 기동 명령
        Sid    = "SSMRecovery"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:DescribeInstanceInformation"
        ]
        Resource = "*"
      },
      {
        # 새 인스턴스에 인덱서 인스턴스 프로파일 부여
        Sid      = "PassIndexerRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${aws_iam_instance_profile.aws-wazuh-indexer-profile.role}"
      }
    ]
  })
}