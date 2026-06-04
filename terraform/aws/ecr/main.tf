# =========================================================
# ECR — Elastic Container Registry
# 2개 리포지토리: aws-hospital-nginx, aws-hospital-api
#
# 보안 설정:
#   - 이미지 태그 불변(IMMUTABLE): 동일 태그 덮어쓰기 방지
#   - 이미지 스캔(scan_on_push): CVE 취약점 자동 탐지 (ISMS-P 2.10.3)
#   - 라이프사이클 정책: 구버전 이미지 자동 삭제 (스토리지 관리)
#   - 프라이빗 리포지토리: 퍼블릭 접근 차단
# =========================================================

data "aws_kms_key" "ecr" {
  key_id = "alias/aws-kms-ecr-01"
}

locals {
  repositories = [
    "aws-hospital-nginx",
    "aws-hospital-api",
  ]

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "최신 ${var.image_retention_count}개 이미지만 보관"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = { type = "expire" }
      }
    ]
  })
}


# ─────────────────────────────────────────────────────────
# ECR 리포지토리
# ─────────────────────────────────────────────────────────
resource "aws_ecr_repository" "repos" {
  for_each = toset(local.repositories)

  name                 = each.key
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = data.aws_kms_key.ecr.arn
  }

  tags = { Name = each.key }
}


# ─────────────────────────────────────────────────────────
# Lifecycle Policy
# ─────────────────────────────────────────────────────────
resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name
  policy     = local.lifecycle_policy
}


# ─────────────────────────────────────────────────────────
# 리포지토리 정책 — 동일 계정 ECS Task 전용 Pull 허용
# 다른 계정/서비스는 접근 차단 (최소 권한 원칙, ISMS-P 2.5.1)
# ─────────────────────────────────────────────────────────
resource "aws_ecr_repository_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECSTaskPull"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
      }
    ]
  })
}
