# =========================================================
# dump_user 비밀번호 로테이션 (ISMS-P 2.5.4)
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
        Resource = [var.rds_secret_arn, var.api_user_secret_arn]
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [data.aws_kms_key.s3.arn]
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
# Lambda 함수 — dump Lambda SG 재사용
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
    security_group_ids = [aws_security_group.db_dump_lambda.id]
  }

  environment {
    variables = {
      RDS_SECRET_ARN = var.rds_secret_arn
      RDS_HOST       = data.aws_db_instance.aurora.address
      RDS_PORT       = "5432"
      DB_NAME        = "hospital"
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

resource "aws_lambda_permission" "secrets_manager_rotation" {
  statement_id  = "AllowSecretsManagerRotation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = var.rds_secret_arn
}

resource "aws_lambda_permission" "secrets_manager_rotation_api_user" {
  statement_id  = "AllowSecretsManagerRotationApiUser"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = var.api_user_secret_arn
}


# ─────────────────────────────────────────────────────────
# Secrets Manager 자동 로테이션
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret_rotation" "dump_user" {
  secret_id           = var.rds_secret_arn
  rotation_lambda_arn = aws_lambda_function.rotation.arn

  rotation_rules {
    automatically_after_days = var.dump_user_rotation_days
  }
}

resource "aws_secretsmanager_secret_rotation" "api_user" {
  secret_id           = var.api_user_secret_arn
  rotation_lambda_arn = aws_lambda_function.rotation.arn

  rotation_rules {
    automatically_after_days = var.api_user_rotation_days
  }
}


# ─────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────
output "rotation_ecr_repository_url" {
  value       = aws_ecr_repository.rotation.repository_url
  description = "rotation 이미지 푸시 대상 ECR URL"
}
