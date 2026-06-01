# =========================================================
# Vault Rotator Lambda
#
# 흐름:
#   Secrets Manager 로테이션 성공 (rds!cluster-...)
#     → EventBridge rule
#     → aws-lambda-vault-rotator
#     → Vault database/config/rds-hospital 업데이트
#
# [마이그레이션] hospital-vault-rotator → aws-lambda-vault-rotator
#   Lambda는 이름 변경 불가 → 새로 생성 후 기존 삭제
# =========================================================

locals {
  vault_rotator_name    = "aws-lambda-vault-rotator"
  vault_rotator_role    = "aws-lambda-vault-rotator-role"
  vault_rotator_cwl     = "/aws/lambda/aws-lambda-vault-rotator"
  vault_rotator_eb_rule = "aws-eb-rds-rotation-to-vault"
}


# ─────────────────────────────────────────────────────────
# Lambda 소스 zip
# ─────────────────────────────────────────────────────────
data "archive_file" "vault_rotator" {
  type        = "zip"
  source_dir  = "${path.module}/container/vault_rotator"
  output_path = "${path.module}/vault_rotator.zip"
}


# ─────────────────────────────────────────────────────────
# IAM Role
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "vault_rotator" {
  name = local.vault_rotator_role

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

resource "aws_iam_role_policy_attachment" "vault_rotator_vpc" {
  role       = aws_iam_role.vault_rotator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "vault_rotator_secrets" {
  name = "secrets-read"
  role = aws_iam_role.vault_rotator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.vault_lambda_approle_v2.arn,
        "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:rds!cluster-1073d242*",
        aws_secretsmanager_secret.jwt_secret_v2.arn,
      ]
    }]
  })
}

resource "aws_cloudwatch_log_group" "vault_rotator" {
  name              = local.vault_rotator_cwl
  retention_in_days = 30
  kms_key_id        = data.aws_kms_key.secretsmanager.arn

  tags = local.common_tags
}


# ─────────────────────────────────────────────────────────
# Lambda 함수
# ─────────────────────────────────────────────────────────
resource "aws_lambda_function" "vault_rotator" {
  function_name    = local.vault_rotator_name
  role             = aws_iam_role.vault_rotator.arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.vault_rotator.output_path
  source_code_hash = data.archive_file.vault_rotator.output_base64sha256
  timeout          = 30

  vpc_config {
    subnet_ids         = var.app_subnet_ids
    security_group_ids = [var.vault_lambda_sg_id]
  }

  environment {
    variables = {
      VAULT_APPROLE_SECRET_ID = aws_secretsmanager_secret.vault_lambda_approle_v2.name
      RDS_SECRET_ID           = "rds!cluster-1073d242-a1f9-49fa-8855-054d05d6af5b"
      JWT_SECRET_ID           = aws_secretsmanager_secret.jwt_secret_v2.name  
      VAULT_DB_CONFIG_PATH    = "database/config/rds-hospital"
      VAULT_AUTH_SECRET_PATH  = "secret/data/hospital-auth"    
      RDS_HOST                = "aws-aurora-01.cluster-cjsaws8mcmwn.ap-south-2.rds.amazonaws.com"
      AWS_REGION_NAME         = var.aws_region
    }
  }

  tags = merge(local.common_tags, { Name = local.vault_rotator_name })

  depends_on = [aws_cloudwatch_log_group.vault_rotator]
}


# ─────────────────────────────────────────────────────────
# EventBridge Rule + Target
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "rds_rotation_to_vault" {
  name        = local.vault_rotator_eb_rule
  description = "RDS 로테이션 및 JWT Secret 변경 시 Vault 자동 업데이트 트리거"

  event_pattern = jsonencode({
    source      = ["aws.secretsmanager"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["RotationSucceeded", "PutSecretValue"]
      additionalEventData = {
        SecretId = [
          "rds!cluster-1073d242-a1f9-49fa-8855-054d05d6af5b",
          aws_secretsmanager_secret.jwt_secret_v2.name
        ]
      }
    }
  })


  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "vault_rotator" {
  rule = aws_cloudwatch_event_rule.rds_rotation_to_vault.name
  arn  = aws_lambda_function.vault_rotator.arn
}

resource "aws_lambda_permission" "eventbridge_vault_rotator" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.vault_rotator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rds_rotation_to_vault.arn
}


# ─────────────────────────────────────────────────────────
# [마이그레이션 완료 후] 기존 리소스 수동 삭제 필요
#
#   aws lambda delete-function \
#     --function-name hospital-vault-rotator \
#     --region ap-south-2
#
#   aws events remove-targets \
#     --rule hospital-rds-rotation-to-vault \
#     --ids <target-id> \
#     --region ap-south-2
#
#   aws events delete-rule \
#     --name hospital-rds-rotation-to-vault \
#     --region ap-south-2
#
#   aws iam delete-role-policy \
#     --role-name hospital-lambda-vault-rotator-role \
#     --policy-name secrets-read
#
#   aws iam detach-role-policy \
#     --role-name hospital-lambda-vault-rotator-role \
#     --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
#
#   aws iam delete-role \
#     --role-name hospital-lambda-vault-rotator-role
# ─────────────────────────────────────────────────────────


