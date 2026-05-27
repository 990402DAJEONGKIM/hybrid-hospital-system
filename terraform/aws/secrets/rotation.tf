# =========================================================
# TC-aws-secrets — Rotation Lambda + 로테이션 설정
#
# dump/rotation.tf에서 이전.
# dump Lambda(lambda.tf)와 분리하여 TC-aws-secrets에서 통합 관리.
# =========================================================


# ─────────────────────────────────────────────────────────
# ECR
# ─────────────────────────────────────────────────────────
resource "aws_ecr_repository" "rotation" {
  name                 = local.rotation_ecr_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = data.aws_kms_key.s3.arn
  }

  tags = merge(local.common_tags, { Name = local.rotation_ecr_name })
}

resource "aws_ecr_lifecycle_policy" "rotation" {
  repository = aws_ecr_repository.rotation.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최근 이미지 3개만 유지"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}


# ─────────────────────────────────────────────────────────
# 보안 그룹 — Rotation Lambda 전용
# (기존: dump Lambda SG 공유 → 분리하여 최소 권한 적용)
# ─────────────────────────────────────────────────────────
resource "aws_security_group" "rotation_lambda" {
  name        = local.rotation_sg_name
  description = "Rotation Lambda - RDS access only"
  vpc_id      = data.aws_vpc.main.id

  egress {
    description = "RDS PostgreSQL"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  egress {
    description = "HTTPS (Secrets Manager via NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = local.rotation_sg_name })
}

resource "aws_security_group_rule" "rds_allow_rotation_lambda" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.rds_security_group_id
  source_security_group_id = aws_security_group.rotation_lambda.id
  description              = "Rotation Lambda password rotation"
}


# ─────────────────────────────────────────────────────────
# IAM
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "rotation_lambda" {
  name = local.rotation_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "rotation_lambda" {
  name = "${local.rotation_role_name}-policy"
  role = aws_iam_role.rotation_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRotation"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
        ]
        # 로테이션 대상 시크릿 전체 — TC-aws-secrets에서 통합 관리
        Resource = [
          # aws_secretsmanager_secret.hospital_user.arn,
          # aws_secretsmanager_secret.api_user.arn,
          aws_secretsmanager_secret.dump_user_v2.arn,
        ]
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [data.aws_kms_key.secretsmanager.arn]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.rotation_cwl_name}:*"
      },
      {
        Sid    = "VPCNetworking"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
    ]
  })
}


# ─────────────────────────────────────────────────────────
# Lambda 함수
# ─────────────────────────────────────────────────────────
resource "aws_lambda_function" "rotation" {
  function_name = local.rotation_name
  role          = aws_iam_role.rotation_lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.rotation.repository_url}:latest"

  timeout     = 60
  memory_size = 256

  vpc_config {
    subnet_ids         = var.rds_subnet_ids
    security_group_ids = [aws_security_group.rotation_lambda.id]
  }

  environment {
    variables = {
      RDS_HOST = data.aws_rds_cluster.aurora.endpoint
      RDS_PORT = "5432"
      DB_NAME  = "hospital"
    }
  }

  lifecycle {
    ignore_changes = [image_uri, source_code_hash]
  }

  tags = merge(local.common_tags, { Name = local.rotation_name })

  depends_on = [aws_ecr_repository.rotation]
}

resource "aws_cloudwatch_log_group" "rotation_lambda" {
  name              = local.rotation_cwl_name
  retention_in_days = 30
  kms_key_id        = data.aws_kms_key.s3.arn
}


# ─────────────────────────────────────────────────────────
# Lambda Permission — Secrets Manager 호출 허용
# ─────────────────────────────────────────────────────────
# resource "aws_lambda_permission" "rotation_hospital_user" {
#   statement_id  = "AllowSecretsManagerRotationHospitalUser"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.rotation.function_name
#   principal     = "secretsmanager.amazonaws.com"
#   source_arn    = aws_secretsmanager_secret.hospital_user.arn
# }

# resource "aws_lambda_permission" "rotation_api_user" {
#   statement_id  = "AllowSecretsManagerRotationApiUser"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.rotation.function_name
#   principal     = "secretsmanager.amazonaws.com"
#   source_arn    = aws_secretsmanager_secret.api_user.arn
# }

resource "aws_lambda_permission" "rotation_dump_user" {
  statement_id  = "AllowSecretsManagerRotationDumpUser"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.dump_user_v2.arn
}


# ─────────────────────────────────────────────────────────
# Secrets Manager 자동 로테이션 설정
# ─────────────────────────────────────────────────────────
# resource "aws_secretsmanager_secret_rotation" "hospital_user" {
#   secret_id           = aws_secretsmanager_secret.hospital_user.arn
#   rotation_lambda_arn = aws_lambda_function.rotation.arn

#   rotation_rules {
#     automatically_after_days = var.hospital_user_rotation_days
#   }

#   depends_on = [aws_lambda_permission.rotation_hospital_user]
# }

# resource "aws_secretsmanager_secret_rotation" "api_user" {
#   secret_id           = aws_secretsmanager_secret.api_user.arn
#   rotation_lambda_arn = aws_lambda_function.rotation.arn

#   rotation_rules {
#     automatically_after_days = var.api_user_rotation_days
#   }

#   depends_on = [aws_lambda_permission.rotation_api_user]
# }

resource "aws_secretsmanager_secret_rotation" "dump_user" {
  secret_id           = aws_secretsmanager_secret.dump_user_v2.arn
  rotation_lambda_arn = aws_lambda_function.rotation.arn

  rotation_rules {
    automatically_after_days = var.dump_user_rotation_days
  }

  depends_on = [aws_lambda_permission.rotation_dump_user]
}