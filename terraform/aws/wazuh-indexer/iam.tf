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