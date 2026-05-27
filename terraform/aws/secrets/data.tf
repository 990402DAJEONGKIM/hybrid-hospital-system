# =========================================================
# TC-aws-secrets — 외부 리소스 참조
# =========================================================

data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────
# KMS (TC-aws-kms 워크스페이스에서 생성)
# ─────────────────────────────────────────────────────────
data "aws_kms_key" "secretsmanager" {
  key_id = "alias/aws-kms-sm-01"
}

data "aws_kms_key" "s3" {
  key_id = "alias/aws-kms-s3-01"
}

# ─────────────────────────────────────────────────────────
# VPC (TC-aws-VPC 워크스페이스에서 생성)
# ─────────────────────────────────────────────────────────
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}

# ─────────────────────────────────────────────────────────
# Aurora (TC-aws-RDS 워크스페이스에서 생성)
# Rotation Lambda 환경변수에 RDS_HOST 주입 시 사용
# ─────────────────────────────────────────────────────────
data "aws_db_instance" "aurora" {
  db_instance_identifier = "aws-aurora-01"
}
