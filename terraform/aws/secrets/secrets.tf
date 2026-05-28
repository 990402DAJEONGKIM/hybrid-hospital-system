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