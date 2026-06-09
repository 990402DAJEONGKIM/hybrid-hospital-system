# ─────────────────────────────────────────────────────────
# dump_user (신규 작명) — RDS 덤프 전용 계정 (7일 로테이션)
# 마이그레이션: hospital/rds/dump-user → aws-rds-dump-user-secret
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "dump_user_v2" {
  name        = "aws-rds-dump-user-secret"
  description = "RDS dump 전용 계정 — dump_user (7일 로테이션, ISMS-P 2.5.4)"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-rds-dump-user-secret" })
}
# ─────────────────────────────────────────────────────────
# pglogical_repl (신규 작명)
# 마이그레이션: rds-pglogical-repl-password → aws-rds-pglogical-password-secret
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "pglogical_repl_v2" {
  name        = "aws-rds-pglogical-password-secret"
  description = "pglogical_repl 계정 비밀번호 — GCP Cloud Function이 로테이션 관리"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-rds-pglogical-password-secret" })
}


# ─────────────────────────────────────────────────────────
# vault/lambda-approle (신규 작명)
# 마이그레이션: hospital/vault/lambda-approle → aws-vault-lambda-approle-secret
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "vault_lambda_approle_v2" {
  name        = "aws-vault-lambda-approle-secret"
  description = "Vault AppRole 자격증명 (Lambda → Vault 인증용)"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-vault-lambda-approle-secret" })
}


# ─────────────────────────────────────────────────────────
# db_url (신규 작명)
# 마이그레이션: hospital/database-url → aws-ecs-patient-database-url-secret
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "db_url_patient_v2" {
  name        = "aws-ecs-patient-database-url-secret"
  description = "ECS 앱 DB 연결 URL"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-ecs-patient-database-url-secret" })
}

# db_url 추가: 기존 db_url은 patient 용으로하고 신규 db_url은 staff 용으로 분리 (by 김다정, 2026.05.28)
resource "aws_secretsmanager_secret" "db_url_staff_v2" {
  name        = "aws-ecs-staff-database-url-secret"
  description = "ECS 앱 DB 연결 URL"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-ecs-staff-database-url-secret" })
}



# ─────────────────────────────────────────────────────────
# jwt_secret (신규 작명)
# 마이그레이션: hospital/jwt-secret → aws-ecs-jwt-secret
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "jwt_secret_v2" {
  name        = "aws-ecs-jwt-secret"
  description = "ECS 앱 JWT 서명 키"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-ecs-jwt-secret" })
}


# ─────────────────────────────────────────────────────────
# api_key (신규 작명)
# 마이그레이션: hospital/api-key → aws-ecs-api-key-secret
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "api_key_v2" {
  name        = "aws-ecs-api-key-secret"
  description = "ECS 앱 API 키"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-ecs-api-key-secret" })
}


# ─────────────────────────────────────────────────────────
# RDS Proxy 유저 자격증명 — 환자 포털 (ecs_patient_user)
# 형식: {"username": "ecs_patient_user", "password": "..."}
# Proxy auth 등록용 — DATABASE_URL 시크릿과 별개
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "proxy_patient_user" {
  name        = "aws-rds-proxy-patient-user-secret"
  description = "RDS Proxy 환자 앱 유저 자격증명 (ecs_patient_user)"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-rds-proxy-patient-user-secret" })
}

# ─────────────────────────────────────────────────────────
# RDS Proxy 유저 자격증명 — 의료진 포털 (ecs_staff_user)
# 형식: {"username": "ecs_staff_user", "password": "..."}
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "proxy_staff_user" {
  name        = "aws-rds-proxy-staff-user-secret"
  description = "RDS Proxy 의료진 앱 유저 자격증명 (ecs_staff_user)"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-rds-proxy-staff-user-secret" })
}



# ─────────────────────────────────────────────────────────
# JWT Secret 로테이션 (ISMS-P 2.5.4)
#
# 로테이션 흐름:
#   1. Secrets Manager가 새 JWT 키 자동 생성
#   2. PutSecretValue 이벤트 → EventBridge
#   3. vault_rotator Lambda → Vault hospital-auth 동기화
#      (jwt_secret_key_previous = 구 키, jwt_secret_key = 신 키)
#   4. ECS 태스크 재배포 → AWSCURRENT/AWSPREVIOUS로 듀얼 키 로딩
#
# 주의: JWT 로테이션은 기존 토큰을 즉시 무효화하지 않음
#       (grace period: AWSPREVIOUS로 검증 유지)
# ─────────────────────────────────────────────────────────

# JWT 로테이션 전용 Lambda (단순 랜덤 키 생성)
resource "aws_lambda_function" "jwt_rotator" {
  function_name = "aws-lambda-jwt-rotator"
  role          = aws_iam_role.jwt_rotator.arn
  runtime       = "python3.12"
  handler       = "index.handler"
  timeout       = 30

  filename         = data.archive_file.jwt_rotator.output_path
  source_code_hash = data.archive_file.jwt_rotator.output_base64sha256

  tags = merge(local.common_tags, { Name = "aws-lambda-jwt-rotator" })

  depends_on = [aws_cloudwatch_log_group.jwt_rotator]
}

data "archive_file" "jwt_rotator" {
  type        = "zip"
  output_path = "${path.module}/jwt_rotator.zip"

  source {
    filename = "index.py"
    content  = <<-PYTHON
import boto3
import json
import secrets
import os

def handler(event, context):
    arn     = event["SecretId"]
    token   = event["ClientRequestToken"]
    step    = event["Step"]
    client  = boto3.client("secretsmanager", region_name=os.environ["AWS_REGION"])

    if step == "createSecret":
        try:
            client.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")
        except client.exceptions.ResourceNotFoundException:
            new_key = secrets.token_hex(64)
            client.put_secret_value(
                SecretId=arn,
                ClientRequestToken=token,
                SecretString=new_key,
                VersionStages=["AWSPENDING"],
            )

    elif step == "setSecret":
        pass  # JWT는 DB 반영 불필요

    elif step == "testSecret":
        val = client.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")
        assert len(val["SecretString"]) >= 64, "키 길이 부족"

    elif step == "finishSecret":
        meta = client.describe_secret(SecretId=arn)
        current_version = next(
            v for v, stages in meta["VersionIdsToStages"].items()
            if "AWSCURRENT" in stages
        )
        if current_version == token:
            return
        client.update_secret_version_stage(
            SecretId=arn,
            VersionStage="AWSCURRENT",
            MoveToVersionId=token,
            RemoveFromVersionId=current_version,
        )
PYTHON
  }
}

resource "aws_cloudwatch_log_group" "jwt_rotator" {
  name              = "/aws/lambda/aws-lambda-jwt-rotator"
  retention_in_days = 30
  kms_key_id        = data.aws_kms_key.secretsmanager.arn

  tags = local.common_tags
}

resource "aws_iam_role" "jwt_rotator" {
  name = "aws-lambda-jwt-rotator-role"

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

resource "aws_iam_role_policy" "jwt_rotator" {
  name = "jwt-rotator-policy"
  role = aws_iam_role.jwt_rotator.id

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
        Resource = [aws_secretsmanager_secret.jwt_secret_v2.arn]
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
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/aws-lambda-jwt-rotator:*"
      },
    ]
  })
}

resource "aws_lambda_permission" "jwt_rotator" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.jwt_rotator.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.jwt_secret_v2.arn
}

# JWT Secret 90일 자동 로테이션 (ISMS-P 2.5.4)
resource "aws_secretsmanager_secret_rotation" "jwt_secret" {
  secret_id           = aws_secretsmanager_secret.jwt_secret_v2.arn
  rotation_lambda_arn = aws_lambda_function.jwt_rotator.arn

  rotation_rules {
    automatically_after_days = 90
  }

  depends_on = [aws_lambda_permission.jwt_rotator]
}
# ─────────────────────────────────────────────────────────
# Wazuh / Keycloak OIDC — wazuh client secret
# 값은 Terraform state에 남기지 않도록 콘솔/CLI로 SecretString을 주입한다.
# [2026-06-10 박경수] Wazuh Dashboard Keycloak SSO용
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "wazuh_openid_client_secret" {
  name        = "aws-wazuh-openid-client-secret"
  description = "Keycloak mzclinic realm의 wazuh OIDC client secret — Wazuh Dashboard SSO"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-wazuh-openid-client-secret" })
}

# ─────────────────────────────────────────────────────────
# Wazuh Dashboard cookie password
# 값은 고정 난수여야 하며, 매 배포마다 바뀌면 OIDC 세션이 무효화된다.
# SecretString 예: openssl rand -hex 32
# [2026-06-10 박경수] Wazuh Dashboard OIDC cookie/session 보호용
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "wazuh_dashboard_cookie_password" {
  name        = "aws-wazuh-dashboard-cookie-password"
  description = "Wazuh Dashboard opensearch_security.cookie.password — OIDC 세션 저장용 고정 secret"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-wazuh-dashboard-cookie-password" })
}
