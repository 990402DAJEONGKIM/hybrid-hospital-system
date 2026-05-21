# =========================================================
# GitHub Actions IAM — ECS 배포 권한 추가
#
# github-actions-ecr-push 역할은 기존에 수동 생성됨.
# data 소스로 참조하여 ECS 권한 정책만 추가.
# =========================================================

data "aws_iam_role" "github_actions" {
  name = "github-actions-ecr-push"
}


# ─────────────────────────────────────────────────────────
# ECS 권한 — Task Definition 등록 & 서비스 배포
# ─────────────────────────────────────────────────────────
resource "aws_iam_role_policy" "github_actions_ecs" {
  name = "github-actions-ecs"
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
