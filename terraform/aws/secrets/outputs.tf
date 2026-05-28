# =========================================================
# TC-aws-secrets — Outputs
# 다른 워크스페이스에서 tfe_outputs로 참조:
#
#   data "tfe_outputs" "secrets" {
#     organization = "<org-name>"
#     workspace    = "TC-aws-secrets"
#   }
#   local.hospital_user_arn = data.tfe_outputs.secrets.values.hospital_user_secret_arn
# =========================================================

# ── 시크릿 ARN ───────────────────────────────────────────
# output "hospital_user_secret_arn" {
#   description = "hospital_user 시크릿 ARN (Vault DB config 연동)"
#   value       = aws_secretsmanager_secret.hospital_user.arn
#   sensitive   = true
# }

# output "api_user_secret_arn" {
#   description = "api_user 시크릿 ARN (레거시 fallback, 90일 로테이션)"
#   value       = aws_secretsmanager_secret.api_user.arn
#   sensitive   = true
# }



# 신규
output "dump_user_secret_arn" {
  description = "dump_user 시크릿 ARN (aws-rds-dump-user-secret)"
  value       = aws_secretsmanager_secret.dump_user_v2.arn
  sensitive   = true
}

output "db_url_secret_arn" {
  description = "hospital/database-url 시크릿 ARN (ECS 앱 DB URL)"
  value       = aws_secretsmanager_secret.db_url.arn
  sensitive   = true
}

output "jwt_secret_arn" {
  description = "hospital/jwt-secret 시크릿 ARN (ECS 앱 JWT 키)"
  value       = aws_secretsmanager_secret.jwt_secret.arn
  sensitive   = true
}

output "api_key_secret_arn" {
  description = "hospital/api-key 시크릿 ARN (ECS 앱 API 키)"
  value       = aws_secretsmanager_secret.api_key.arn
  sensitive   = true
}

output "vault_lambda_approle_secret_arn" {
  description = "hospital/vault/lambda-approle 시크릿 ARN (Lambda → Vault 인증)"
  value       = aws_secretsmanager_secret.vault_lambda_approle.arn
  sensitive   = true
}

# ── Rotation Lambda ───────────────────────────────────────
output "rotation_lambda_arn" {
  description = "Rotation Lambda ARN (dump 워크스페이스 참조용)"
  value       = aws_lambda_function.rotation.arn
}

output "rotation_ecr_repository_url" {
  description = "Rotation 이미지 푸시 대상 ECR URL"
  value       = aws_ecr_repository.rotation.repository_url
}




# 신규
output "pglogical_repl_secret_arn" {
  description = "pglogical_repl 시크릿 ARN (aws-rds-pglogical-password-secret)"
  value       = aws_secretsmanager_secret.pglogical_repl_v2.arn
  sensitive   = true
}