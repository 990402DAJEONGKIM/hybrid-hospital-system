# =========================================================
# ecs_db_rotator — ECS 앱 DB 계정 비밀번호 로테이션 Lambda
#
# 역할: ecs_patient_user / ecs_staff_user 비밀번호를 90일마다 교체
#   1. createSecret  — 새 비밀번호 생성 → AWSPENDING 저장
#   2. setSecret     — hospital_user(master)로 RDS ALTER USER 실행
#   3. testSecret    — 새 비밀번호로 DB 접속 검증
#   4. finishSecret  — AWSPENDING → AWSCURRENT 확정
#
# 배포 주의:
#   ECR 이미지가 없으면 Lambda 생성 실패.
#   최초 적용 순서:
#     1) terraform apply -target=aws_ecr_repository.ecs_db_rotator
#     2) Docker 이미지 빌드 & ECR 푸시
#     3) terraform apply
# =========================================================


# ── ECR ──────────────────────────────────────────────────
resource "aws_ecr_repository" "ecs_db_rotator" {
  name                 = "aws-ecr-ecs-db-rotator"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, { Name = "aws-ecr-ecs-db-rotator" })
}


# ── CloudWatch Logs ───────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs_db_rotator" {
  name              = "/aws/lambda/aws-lambda-ecs-db-rotator"
  retention_in_days = 90
  tags = merge(local.common_tags, { Name = "aws-cwl-ecs-db-rotator" })
}


# ── 보안 그룹 (Lambda → RDS 접근) ─────────────────────────
resource "aws_security_group" "ecs_db_rotator" {
  name        = "aws-ecs-db-rotator-sg"
  description = "ECS DB rotator Lambda security group"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "RDS Aurora"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Secrets Manager HTTPS"
  }

  tags = merge(local.common_tags, { Name = "aws-ecs-db-rotator-sg" })
}


# ── IAM Role ──────────────────────────────────────────────
resource "aws_iam_role" "ecs_db_rotator" {
  name = "aws-lambda-ecs-db-rotator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "aws-lambda-ecs-db-rotator-role" })
}

resource "aws_iam_role_policy" "ecs_db_rotator" {
  name = "ecs-db-rotator-policy"
  role = aws_iam_role.ecs_db_rotator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # patient / staff 시크릿 읽기 + 쓰기 (로테이션 4단계)
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:UpdateSecretVersionStage",
        ]
        Resource = [
          data.tfe_outputs.secrets.values.db_url_patient_secret_arn,
          data.tfe_outputs.secrets.values.db_read_url_patient_secret_arn,
        ]
      },
      {
        # hospital_user master 시크릿 읽기 (ALTER USER 실행용)
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [data.aws_rds_cluster.main.master_user_secret[0].secret_arn]
      },
      {
        # Proxy auth 시크릿 업데이트 (ALTER USER 후 비밀번호 동기화)
        Effect   = "Allow"
        Action   = ["secretsmanager:PutSecretValue"]
        Resource = [
          data.tfe_outputs.secrets.values.proxy_patient_user_secret_arn,
          data.tfe_outputs.secrets.values.proxy_staff_user_secret_arn,
        ]
      },
      {
        # KMS 복호화 (시크릿 암호화 키)
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [data.aws_kms_key.secretsmanager.arn]
      },
      {
        # VPC ENI 관리 (Lambda VPC 실행 필수)
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = ["*"]
      },
      {
        # CloudWatch Logs
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.ecs_db_rotator.arn}:*"
      }
    ]
  })
}


# ── Lambda ────────────────────────────────────────────────
resource "aws_lambda_function" "ecs_db_rotator" {
  function_name = "aws-lambda-ecs-db-rotator"
  role          = aws_iam_role.ecs_db_rotator.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.ecs_db_rotator.repository_url}:latest"
  timeout       = 60

  vpc_config {
    subnet_ids         = data.aws_subnets.app.ids
    security_group_ids = [aws_security_group.ecs_db_rotator.id]
  }

  environment {
    variables = {
      MASTER_SECRET_ARN        = data.aws_rds_cluster.main.master_user_secret[0].secret_arn
      PROXY_PATIENT_SECRET_ARN = data.tfe_outputs.secrets.values.proxy_patient_user_secret_arn
      PROXY_STAFF_SECRET_ARN   = data.tfe_outputs.secrets.values.proxy_staff_user_secret_arn
      AURORA_HOST              = data.aws_rds_cluster.main.endpoint
    }
  }

  lifecycle {
    ignore_changes = [image_uri]
  }

  tags = merge(local.common_tags, { Name = "aws-lambda-ecs-db-rotator" })
}


# ── Secrets Manager → Lambda 호출 권한 ────────────────────
resource "aws_lambda_permission" "secretsmanager_patient" {
  statement_id  = "AllowSecretsManagerRotationPatient"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ecs_db_rotator.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = data.tfe_outputs.secrets.values.db_url_patient_secret_arn
}

resource "aws_lambda_permission" "secretsmanager_reader" {
  statement_id  = "AllowSecretsManagerRotationReader"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ecs_db_rotator.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = data.tfe_outputs.secrets.values.db_read_url_patient_secret_arn
}


# ── Secrets Manager 로테이션 설정 (90일) ──────────────────
resource "aws_secretsmanager_secret_rotation" "patient_db_url" {
  secret_id           = data.tfe_outputs.secrets.values.db_url_patient_secret_arn
  rotation_lambda_arn = aws_lambda_function.ecs_db_rotator.arn

  rotation_rules {
    automatically_after_days = 90
  }
}

resource "aws_secretsmanager_secret_rotation" "reader_db_url" {
  secret_id           = data.tfe_outputs.secrets.values.db_read_url_patient_secret_arn
  rotation_lambda_arn = aws_lambda_function.ecs_db_rotator.arn

  rotation_rules {
    automatically_after_days = 90
  }
}
