# =========================================================
# TC-aws-secrets — Secrets Manager 시크릿 정의
#
# [현재 상태] 시크릿은 콘솔/수동으로 이미 생성되어 있음.
#   apply 전 반드시 import 먼저 실행:
#
#   terraform import aws_secretsmanager_secret.hospital_user \
#     arn:aws:secretsmanager:ap-south-2:476293896981:secret:aws-secret-rds-hospital-user-XXXXXX
#   terraform import aws_secretsmanager_secret.api_user \
#     arn:aws:secretsmanager:ap-south-2:476293896981:secret:aws-secret-rds-api-user-XXXXXX
#   terraform import aws_secretsmanager_secret.dump_user \
#     arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/rds/dump-user-XXXXXX
#   terraform import aws_secretsmanager_secret.db_url \
#     arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/database-url-XXXXXX
#   terraform import aws_secretsmanager_secret.jwt_secret \
#     arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/jwt-secret-XXXXXX
#   terraform import aws_secretsmanager_secret.api_key \
#     arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/api-key-XXXXXX
#   terraform import aws_secretsmanager_secret.vault_lambda_approle \
#     arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/vault/lambda-approle-XXXXXX
#
#   정확한 ARN은 아래 명령으로 확인:
#   aws secretsmanager list-secrets --region ap-south-2 \
#     --query 'SecretList[].{Name:Name,ARN:ARN}' --output table
# =========================================================


# ─────────────────────────────────────────────────────────
# hospital_user — Vault DB config 연동 계정 (7일 로테이션)
# EventBridge → aws-lambda-vault-rotator → Vault database/config 업데이트
# ─────────────────────────────────────────────────────────
# resource "aws_secretsmanager_secret" "hospital_user" {
#   name        = "aws-secret-rds-hospital-user"
#   description = "Vault Dynamic Secrets 발급용 관리자 계정 — hospital_user (7일 로테이션)"
#   kms_key_id  = data.aws_kms_key.secretsmanager.arn

#   lifecycle {
#     prevent_destroy = true
#   }

#   tags = merge(local.common_tags, { Name = "aws-secret-rds-hospital-user" })
# }


# ─────────────────────────────────────────────────────────
# api_user — 레거시 호환 계정 (90일 로테이션)
# ECS 앱이 Vault 없이 접근하던 정적 계정.
# 현재는 fallback 용도 (실제 앱은 Vault Dynamic Secrets 사용).
# ─────────────────────────────────────────────────────────
# resource "aws_secretsmanager_secret" "api_user" {
#   name        = "aws-secret-rds-api-user"
#   description = "레거시 호환 계정 — api_user (90일 로테이션, ISMS-P 2.5.4)"
#   kms_key_id  = data.aws_kms_key.secretsmanager.arn

#   lifecycle {
#     prevent_destroy = true
#   }

#   tags = merge(local.common_tags, { Name = "aws-secret-rds-api-user" })
# }



# ─────────────────────────────────────────────────────────
# ECS 앱 시크릿 — 팀원 워크스페이스(TC-aws-ECS)에서 참조
#
# [현재 상태] TC-aws-ECS/data.tf가 name으로 data source 조회 중:
#   data "aws_secretsmanager_secret" "db_url" { name = "hospital/database-url" }
#   → 지금 상태 그대로 동작함. 변경 불필요.
#
# [마이그레이션 후] TC-aws-ECS/data.tf를 tfe_outputs로 교체 가능:
#   data "tfe_outputs" "secrets" {
#     organization = "<org>"
#     workspace    = "TC-aws-secrets"
#   }
#   → data.tfe_outputs.secrets.values.db_url_secret_arn 으로 참조
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "db_url" {
  name        = "hospital/database-url"
  description = "ECS 앱 DB 연결 URL (hospital/database-url)"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-secret-ecs-db-url" })
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name        = "hospital/jwt-secret"
  description = "ECS 앱 JWT 서명 키"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-secret-ecs-jwt" })
}

resource "aws_secretsmanager_secret" "api_key" {
  name        = "hospital/api-key"
  description = "ECS 앱 API 키"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-secret-ecs-api-key" })
}


# ─────────────────────────────────────────────────────────
# vault/lambda-approle — Vault 연동 Lambda AppRole 자격증명
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "vault_lambda_approle" {
  name        = "hospital/vault/lambda-approle"
  description = "Vault AppRole 자격증명 (Lambda → Vault 인증용)"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-secret-vault-lambda-approle" })
}
# ─────────────────────────────────────────────────────────
# pglogical_repl — Aurora ↔ GCP Cloud SQL 복제 계정
#
# [로테이션 주의] aws-lambda-rotation으로 돌리면 안 됨.
# GCP Cloud Function(gcp-fn-cloudsql-rotation)이 Aurora + Cloud SQL
# 양쪽 동시 변경 후 이 시크릿을 업데이트함.
# 로테이션 주기: 7일 (Cloud Scheduler → GCP Cloud Function)
# ─────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "pglogical_repl" {
  name        = "rds-pglogical-repl-password"
  description = "pglogical_repl 계정 비밀번호 — GCP Cloud Function이 로테이션 관리"
  kms_key_id  = data.aws_kms_key.secretsmanager.arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "rds-pglogical-repl-password" })
}
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

# # =========================================================
# # Import 블록 — 기존 리소스 가져오기
# # apply 완료 후 이 블록 전체 삭제
# # =========================================================
import {
  to = aws_secretsmanager_secret.pglogical_repl
  id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:rds-pglogical-repl-password-eGMZTP"
}
# import {
#   to = aws_secretsmanager_secret.hospital_user
#   id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:aws-secret-rds-hospital-user-mRfEDx"
# }

# import {
#   to = aws_secretsmanager_secret.api_user
#   id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:aws-secret-rds-api-user-iMV55M"
# }

# import {
#   to = aws_secretsmanager_secret.dump_user
#   id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/rds/dump-user-Rii7x3"
# }

# import {
#   to = aws_secretsmanager_secret.db_url
#   id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/database-url-20p2Rp"
# }

# import {
#   to = aws_secretsmanager_secret.jwt_secret
#   id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/jwt-secret-jmOkOF"
# }

# import {
#   to = aws_secretsmanager_secret.api_key
#   id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/api-key-3vJc1u"
# }

# import {
#   to = aws_secretsmanager_secret.vault_lambda_approle
#   id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:hospital/vault/lambda-approle-NnWr5j"
# }

# import {
#   to = aws_ecr_repository.rotation
#   id = "aws-ecr-rotation"
# }

# import {
#   to = aws_cloudwatch_log_group.rotation_lambda
#   id = "/aws/lambda/aws-lambda-rotation"
# }

# import {
#   to = aws_lambda_function.rotation
#   id = "aws-lambda-rotation"
# }

# import {
#   to = aws_iam_role.rotation_lambda
#   id = "aws-lambda-rotation-role"
# }
# import {
#   to = aws_lambda_permission.rotation_api_user
#   id = "aws-lambda-rotation/AllowSecretsManagerRotationApiUser"
# }
# import {
#   to = aws_lambda_permission.rotation_hospital_user
#   id = "aws-lambda-rotation/AllowSecretsManagerRotationHospitalUser"
# }

# import {
#   to = aws_lambda_permission.rotation_dump_user
#   id = "aws-lambda-rotation/AllowSecretsManagerRotationDumpUser"
# }