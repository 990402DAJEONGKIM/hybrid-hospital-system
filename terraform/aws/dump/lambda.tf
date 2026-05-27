# =========================================================
# DB Dump Lambda — RDS Aurora → S3 (db-dumps/rds/)
# =========================================================


# ─────────────────────────────────────────────────────────
# ECR
# ─────────────────────────────────────────────────────────
resource "aws_ecr_repository" "db_dump" {
  name                 = local.dump_ecr_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = data.aws_kms_key.s3.arn
  }

  tags = merge(local.common_tags, { Name = local.dump_ecr_name })
}

resource "aws_ecr_lifecycle_policy" "db_dump" {
  repository = aws_ecr_repository.db_dump.name

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
# 보안 그룹
# ─────────────────────────────────────────────────────────
resource "aws_security_group" "db_dump_lambda" {
  name        = local.dump_sg_name
  description = "DB Dump Lambda outbound"
  vpc_id      = data.aws_vpc.main.id

  egress {
    description = "RDS PostgreSQL"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  egress {
    description = "HTTPS (S3, Secrets Manager, ECR via NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = local.dump_sg_name })
}

resource "aws_security_group_rule" "rds_allow_dump_lambda" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.rds_security_group_id
  source_security_group_id = aws_security_group.db_dump_lambda.id
  description              = "DB Dump Lambda pg_dump"
}


# ─────────────────────────────────────────────────────────
# IAM
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "db_dump_lambda" {
  name = local.dump_role_name

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

resource "aws_iam_role_policy" "db_dump_lambda" {
  name = "${local.dump_role_name}-policy"
  role = aws_iam_role.db_dump_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.dump_user_secret_arn]

      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [
          data.aws_kms_key.s3.arn,
          data.aws_kms_key.secretsmanager.arn,
         ]
      },
      {
        Sid    = "S3Upload"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:ListBucket"]
        Resource = [
          data.aws_s3_bucket.storage.arn,
          "${data.aws_s3_bucket.storage.arn}/${local.dump_s3_prefix}/*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.dump_cwl_name}:*"
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
resource "aws_lambda_function" "db_dump" {
  function_name = local.dump_name
  role          = aws_iam_role.db_dump_lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.db_dump.repository_url}:latest"

  timeout     = var.db_dump_lambda_timeout
  memory_size = var.db_dump_lambda_memory

  vpc_config {
    subnet_ids         = var.rds_subnet_ids
    security_group_ids = [aws_security_group.db_dump_lambda.id]
  }

  environment {
    variables = {
      RDS_SECRET_ARN = local.dump_user_secret_arn
      RDS_HOST       = data.aws_rds_cluster.aurora.endpoint
      RDS_PORT       = "5432"
      DB_NAME        = "hospital"
      S3_BUCKET      = data.aws_s3_bucket.storage.bucket
      S3_PREFIX      = local.dump_s3_prefix
    }
  }

  lifecycle {
    ignore_changes = [image_uri, source_code_hash]
  }

  tags = merge(local.common_tags, { Name = local.dump_name })

  depends_on = [aws_ecr_repository.db_dump]
}

resource "aws_cloudwatch_log_group" "db_dump_lambda" {
  name              = local.dump_cwl_name
  retention_in_days = 30
  kms_key_id        = data.aws_kms_key.s3.arn
}


# ─────────────────────────────────────────────────────────
# EventBridge Scheduler
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "scheduler" {
  name = "${local.dump_sch_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.dump_sch_name}-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.db_dump.arn
    }]
  })
}

resource "aws_scheduler_schedule" "db_dump" {
  name        = local.dump_sch_name
  description = "RDS hospital DB 덤프 → S3"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }

  schedule_expression          = local.dump_schedule
  schedule_expression_timezone = "Asia/Seoul"

  target {
    arn      = aws_lambda_function.db_dump.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}


# ─────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────
output "ecr_repository_url" {
  value       = aws_ecr_repository.db_dump.repository_url
  description = "dump 이미지 푸시 대상 ECR URL"
}
