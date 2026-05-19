# ─────────────────────────────────────────────────────────
# KMS 키 ARN 출력 — 다른 모듈에서 참조
# (RDS, ECS, S3, CloudFront, Secrets Manager 모듈에서 사용)
# ─────────────────────────────────────────────────────────

output "rds_kms_key_arn" {
  description = "Aurora RDS 암호화용 KMS 키 ARN"
  value       = aws_kms_key.rds.arn
}

output "rds_kms_key_id" {
  description = "Aurora RDS 암호화용 KMS 키 ID"
  value       = aws_kms_key.rds.key_id
}

output "ebs_kms_key_arn" {
  description = "EBS 볼륨 암호화용 KMS 키 ARN"
  value       = aws_kms_key.ebs.arn
}

output "ebs_kms_key_id" {
  description = "EBS 볼륨 암호화용 KMS 키 ID"
  value       = aws_kms_key.ebs.key_id
}

output "s3_kms_key_arn" {
  description = "S3 버킷 암호화용 KMS 키 ARN"
  value       = aws_kms_key.s3.arn
}

output "s3_kms_key_id" {
  description = "S3 버킷 암호화용 KMS 키 ID"
  value       = aws_kms_key.s3.key_id
}

output "secretsmanager_kms_key_arn" {
  description = "Secrets Manager 암호화용 KMS 키 ARN"
  value       = aws_kms_key.secretsmanager.arn
}

output "secretsmanager_kms_key_id" {
  description = "Secrets Manager 암호화용 KMS 키 ID"
  value       = aws_kms_key.secretsmanager.key_id
}
