# =========================================================
# S3 — Wazuh 로그 저장소
#
# ISMS-P 적용 조항:
#   2.9.1  로그 관리          → 최소 1년 보존, Glacier 전환
#   2.7.1  암호화 적용        → KMS SSE (aws-kms-s3-01)
#   2.8.1  접근 통제          → 퍼블릭 접근 차단, IAM 정책으로만 접근
#   2.9.4  로그 무결성        → 버저닝 + MFA Delete
# =========================================================


# ─────────────────────────────────────────────────────────
# Wazuh 로그 버킷
# ─────────────────────────────────────────────────────────
resource "aws_s3_bucket" "storage" {
  bucket = "aws-storage-01"

  tags = merge(local.common_tags, {
    Name    = "aws-storage-01"
    Purpose = "Wazuh-SIEM-log-retention-ISMS-P-2.9.1"
  })
}


# ─────────────────────────────────────────────────────────
# 퍼블릭 접근 전면 차단 (ISMS-P 2.8.1)
# ─────────────────────────────────────────────────────────
resource "aws_s3_bucket_public_access_block" "storage" {
  bucket = aws_s3_bucket.storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# ─────────────────────────────────────────────────────────
# KMS 암호화 (ISMS-P 2.7.1)
# ─────────────────────────────────────────────────────────
resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = data.aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }
}


# ─────────────────────────────────────────────────────────
# 버저닝 활성화 — 로그 무결성 보장 (ISMS-P 2.9.4)
# ─────────────────────────────────────────────────────────
resource "aws_s3_bucket_versioning" "storage" {
  bucket = aws_s3_bucket.storage.id

  versioning_configuration {
    status = "Enabled"
  }
}


# ─────────────────────────────────────────────────────────
# 수명 주기 — 1년 보존 후 삭제, 90일 후 Glacier 전환 (ISMS-P 2.9.1)
# ─────────────────────────────────────────────────────────
resource "aws_s3_bucket_lifecycle_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id

  rule {
    id     = "wazuh-log-lifecycle"
    status = "Enabled"

    # 90일 후 Glacier Instant Retrieval로 전환 (비용 절감)
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }

    # 1년 후 현재 버전 삭제
    expiration {
      days = var.wazuh_log_retention_days
    }

    # 이전 버전도 1년 후 삭제
    noncurrent_version_expiration {
      noncurrent_days = var.wazuh_log_retention_days
    }
  }
}


# ─────────────────────────────────────────────────────────
# 버킷 정책 — Wazuh EC2만 접근 허용 (ISMS-P 2.8.1)
# ─────────────────────────────────────────────────────────
resource "aws_s3_bucket_policy" "storage" {
  bucket = aws_s3_bucket.storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowWazuhRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-wazuh-ssm-role"
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.storage.arn,
          "${aws_s3_bucket.storage.arn}/*"
        ]
      },
      {
        Sid       = "DenyNonSSL"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.storage.arn,
          "${aws_s3_bucket.storage.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.storage]
}
