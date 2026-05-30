# =========================================================
# S3 — Wazuh 로그 저장소
#
# ISMS-P 적용 조항:
#   2.9.1  로그 관리          → 최소 1년 보존, Glacier 전환
#   2.7.1  암호화 적용        → KMS SSE (aws-kms-s3-01)
#   2.8.1  접근 통제          → 퍼블릭 접근 차단, IAM 정책으로만 접근
#   2.9.4  로그 무결성        → 버저닝 + MFA Delete
# =========================================================
# =========================================================
# + DB 덤프 prefix
# =========================================================

# ─────────────────────────────────────────────────────────
# Wazuh 로그 버킷
# ─────────────────────────────────────────────────────────
resource "aws_s3_bucket" "storage" {
  bucket = "aws-k2p-storage-01"

  tags = merge(local.common_tags, {
    Name    = "aws-k2p-storage-01"
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
    filter {} 

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
    # 추가: DB 덤프 30일 보존 - 20260526 st1 추가
  rule {
    id     = "db-dump-lifecycle"
    status = "Enabled"
    filter {
      prefix = "db-dumps/"
    }
    expiration {
      days = var.db_dump_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  # 추가: GitHub Actions 백업 90일 보존 (20260530, by 김다정)
    rule {
    id     = "github-backup-lifecycle"
    status = "Enabled"
    filter {
      prefix = "github-backup/"
    }
    expiration {
      days = var.github_backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
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
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.storage.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid    = "AllowGuardDutyGetBucketLocation"
        Effect = "Allow"
        Principal = { Service = "guardduty.amazonaws.com" }
        Action   = "s3:GetBucketLocation"
        Resource = aws_s3_bucket.storage.arn
      },
      {
        Sid    = "AllowGuardDutyPutObject"
        Effect = "Allow"
        Principal = { Service = "guardduty.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/guardduty/*"
      },
      {
        Sid    = "AWSFlowLogsWrite"
        Effect = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/flowlogs/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid    = "AWSFlowLogsAclCheck"
        Effect = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.storage.arn
      },
      # {
      #   Sid    = "ALBLogDelivery"
      #   Effect = "Allow"
      #   Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
      #   Action   = "s3:PutObject"
      #   Resource = "${aws_s3_bucket.storage.arn}/alb/*"
      #   Condition = {
      #     StringEquals = {
      #       "s3:x-amz-acl"     = "bucket-owner-full-control"
      #       "aws:SourceAccount" = data.aws_caller_identity.current.account_id
      #     }
      #   }
      # },
      # {
      #   Sid    = "ALBLogAclCheck"
      #   Effect = "Allow"
      #   Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
      #   Action   = "s3:GetBucketAcl"
      #   Resource = aws_s3_bucket.storage.arn
      #   Condition = {
      #     StringEquals = {
      #       "aws:SourceAccount" = data.aws_caller_identity.current.account_id
      #     }
      #   }
      # },

      # 추가: GitHub Actions 백업 권한 (20260530, by 김다정)
      {
        Sid    = "AllowGitHubActionsListBucket"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-github-actions-ecr-push"
        }
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.storage.arn
        Condition = {
          StringLike = { "s3:prefix" = ["github-backup/*"] }
        }
      },
      {
        Sid    = "AllowGitHubActionsObjectOps"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-github-actions-ecr-push"
        }
        Action = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.storage.arn}/github-backup/*"
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
          Bool = { "aws:SecureTransport" = "false" }
          StringNotEqualsIfExists = {
            "aws:PrincipalServiceNamesList" = [
              "logdelivery.elasticloadbalancing.amazonaws.com",
              "cloudtrail.amazonaws.com",
              "guardduty.amazonaws.com",
              "delivery.logs.amazonaws.com",
              "firehose.amazonaws.com"
            ]
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.storage]
}
