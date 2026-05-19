# =========================================================
# KMS — 고객 관리형 키 (CMK)
# ISMS-P 2.7.1: 암호키 관리 (생성·교체·폐기 정책 수립)
#
# 키 분리 전략:
#   - rds  : Aurora DB 저장 데이터 암호화
#   - ebs  : EC2 EBS 볼륨 암호화 (ECS EC2 노드)
#   - s3   : S3 버킷 암호화 (로그, 정적 파일, 백업)
#   - sm   : Secrets Manager 암호화 (DB 자격증명 등)
# =========================================================


# ─────────────────────────────────────────────────────────
# 공통 키 정책 (루트 계정 전체 권한 + 키 관리자만 관리 가능)
# ─────────────────────────────────────────────────────────
locals {
  key_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 루트 계정에 전체 권한 부여 (IAM 정책으로 추가 제어 가능)
        Sid    = "EnableRootAccountPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # CloudWatch Logs가 암호화 키 사용 가능하도록 허용
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}


# ─────────────────────────────────────────────────────────
# 1. RDS 암호화 키
#    Aurora 클러스터 저장 데이터 (at-rest) 암호화
#    개인정보보호법 제29조, ISMS-P 2.7.1
# ─────────────────────────────────────────────────────────
resource "aws_kms_key" "rds" {
  description             = "Hospital RDS Aurora 저장 데이터 암호화 키"
  enable_key_rotation     = true
  rotation_period_in_days = var.key_rotation_period_days
  deletion_window_in_days = var.deletion_window_days
  policy                  = local.key_policy

  tags = {
    Name    = "aws-kms-rds-01"
    Purpose = "rds-encryption"
  }
}

resource "aws_kms_alias" "rds" {
  name          = "alias/hospital-rds"
  target_key_id = aws_kms_key.rds.key_id
}


# ─────────────────────────────────────────────────────────
# 2. EBS 암호화 키
#    ECS EC2 노드의 루트 볼륨 및 데이터 볼륨 암호화
#    ISMS-P 2.7.1
# ─────────────────────────────────────────────────────────
resource "aws_kms_key" "ebs" {
  description             = "Hospital EC2 EBS 볼륨 암호화 키"
  enable_key_rotation     = true
  rotation_period_in_days = var.key_rotation_period_days
  deletion_window_in_days = var.deletion_window_days
  policy                  = local.key_policy

  tags = {
    Name    = "aws-kms-ebs-01"
    Purpose = "ebs-encryption"
  }
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/hospital-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}


# ─────────────────────────────────────────────────────────
# 3. S3 암호화 키
#    로그 버킷, 정적 파일 버킷, 백업 버킷 암호화
#    개인정보보호법 제29조, ISMS-P 2.7.1
# ─────────────────────────────────────────────────────────
resource "aws_kms_key" "s3" {
  description             = "Hospital S3 버킷 암호화 키 (로그/정적파일/백업)"
  enable_key_rotation     = true
  rotation_period_in_days = var.key_rotation_period_days
  deletion_window_in_days = var.deletion_window_days
  policy                  = local.key_policy

  tags = {
    Name    = "aws-kms-s3-01"
    Purpose = "s3-encryption"
  }
}

resource "aws_kms_alias" "s3" {
  name          = "alias/hospital-s3"
  target_key_id = aws_kms_key.s3.key_id
}


# ─────────────────────────────────────────────────────────
# 4. Secrets Manager 암호화 키
#    DB 자격증명, JWT Secret, API Key 등 비밀값 암호화
#    ISMS-P 2.7.1 / 2.5.1 접근통제
# ─────────────────────────────────────────────────────────
resource "aws_kms_key" "secretsmanager" {
  description             = "Hospital Secrets Manager 암호화 키"
  enable_key_rotation     = true
  rotation_period_in_days = var.key_rotation_period_days
  deletion_window_in_days = var.deletion_window_days
  policy                  = local.key_policy

  tags = {
    Name    = "aws-kms-sm-01"
    Purpose = "secretsmanager-encryption"
  }
}

resource "aws_kms_alias" "secretsmanager" {
  name          = "alias/hospital-secretsmanager"
  target_key_id = aws_kms_key.secretsmanager.key_id
}


# ─────────────────────────────────────────────────────────
# EBS 기본 암호화 활성화
# 이 설정 이후 생성되는 모든 EBS 볼륨에 자동으로 암호화 적용
# ISMS-P 2.7.1
# ─────────────────────────────────────────────────────────
resource "aws_ebs_encryption_by_default" "enabled" {
  enabled = true
}

resource "aws_ebs_default_kms_key" "hospital" {
  key_arn = aws_kms_key.ebs.arn
}
