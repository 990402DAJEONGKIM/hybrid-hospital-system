# =========================================================
# GitHub Actions IAM — ECS 배포 & 백업 권한
#
# Terraform으로 역할 직접 관리 (기존 수동 생성 역할 대체)
# =========================================================

resource "aws_iam_role" "github_actions" {
  name = "aws-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:990402DAJEONGKIM/hybrid-hospital-system:*"
          }
        }
      }
    ]
  })
}


# ─────────────────────────────────────────────────────────
# ECR 관리형 정책 연결
# ─────────────────────────────────────────────────────────
resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}


# ─────────────────────────────────────────────────────────
# ECS 권한 — Task Definition 등록 & 서비스 배포
# ─────────────────────────────────────────────────────────
resource "aws_iam_role_policy" "github_actions_ecs" {
  name = "aws-github-actions-ecs"
  role = aws_iam_role.github_actions.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeServices",
          "ecs:UpdateService",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          "arn:aws:iam::${var.aws_account_id}:role/aws-ecs-task-execution-role",
          "arn:aws:iam::${var.aws_account_id}:role/aws-ecs-task-role",
        ]
      }
    ]
  })
}


# ─────────────────────────────────────────────────────────
# KMS 키 참조 — S3 버킷 암호화 키 (ISMS-P 2.7.1)
# ─────────────────────────────────────────────────────────
data "aws_kms_key" "s3" {
  key_id = "alias/aws-kms-s3-01"
}


# ─────────────────────────────────────────────────────────
# S3 백업 권한 — 소스코드 & tfstate 백업용
# ISMS-P 2.6.2 최소 권한: github-backup/* 경로만 허용
# ISMS-P 2.7.1 암호화:    KMS 키 ARN 고정
# ─────────────────────────────────────────────────────────
resource "aws_iam_role_policy" "github_actions_s3_backup" {
  name = "aws-github-actions-s3-backup"
  role = aws_iam_role.github_actions.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowS3ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::aws-k2p-storage-01"]
        Condition = {
          StringLike = { "s3:prefix" = ["github-backup/*"] }
        }
      },
      {
        Sid      = "AllowS3ObjectOps"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["arn:aws:s3:::aws-k2p-storage-01/github-backup/*"]
      },
      {
        Sid      = "AllowKMSForS3Backup"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [data.aws_kms_key.s3.arn]
      }
    ]
  })
}
