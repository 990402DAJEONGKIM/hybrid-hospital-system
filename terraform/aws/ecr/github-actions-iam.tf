# =========================================================
# GitHub Actions IAM — ECS 배포 권한 추가
#
# github-actions-ecr-push 역할은 기존에 수동 생성됨.
# data 소스로 참조하여 ECS 권한 정책만 추가.
# =========================================================

data "aws_iam_role" "github_actions" {
  name = "aws-github-actions-ecr-push"
}


# ─────────────────────────────────────────────────────────
# ECS 권한 — Task Definition 등록 & 서비스 배포
# ─────────────────────────────────────────────────────────
resource "aws_iam_role_policy" "github_actions_ecs" {
  name = "aws-github-actions-ecs"
  role = data.aws_iam_role.github_actions.name

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
        Action = [
          "iam:PassRole",
        ]
        Resource = [
          "arn:aws:iam::${var.aws_account_id}:role/aws-ecs-task-execution-role",
          "arn:aws:iam::${var.aws_account_id}:role/aws-ecs-task-role",
        ]
      }
    ]
  })
}


# 추가: 소스코드 & tfstate 백업용 S3 권한 추가 — ISMS-P 백업 정책 대응 (20260530, by 김다정)
# ─────────────────────────────────────────────────────────
# S3 백업 권한 — 소스코드 & tfstate 백업용
# ISMS-P 백업 정책 대응
# ─────────────────────────────────────────────────────────
data "aws_kms_key" "s3" {
  key_id = "alias/aws-kms-s3-01"
}

resource "aws_iam_role_policy" "github_actions_s3_backup" {
  name = "aws-github-actions-s3-backup"
  role = data.aws_iam_role.github_actions.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3ListBucket"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::aws-k2p-storage-01"]
        Condition = {
          StringLike = { "s3:prefix" = ["github-backup/*"] }
        }
      },
      {
        Sid    = "AllowS3ObjectOps"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject"]
        Resource = ["arn:aws:s3:::aws-k2p-storage-01/github-backup/*"]
      },
      {
        Sid    = "AllowKMSForS3Backup"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [data.aws_kms_key.s3.arn]
      }
    ]
  })
}
