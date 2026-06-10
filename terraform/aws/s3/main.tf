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

  # ── 보안 감사 로그 365일 (ISMS-P 2.9.1 필수) ────────────
  # ── 보안 감사 로그 365일 (ISMS-P 2.9.1 필수) ────────────
  rule {
    id     = "cloudtrail-lifecycle"
    status = "Enabled"
    filter { prefix = "cloudtrail/" }
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.wazuh_log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  rule {
    id     = "guardduty-lifecycle"
    status = "Enabled"
    filter { prefix = "guardduty/" }
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.wazuh_log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  rule {
    id     = "wazuh-alerts-lifecycle"
    status = "Enabled"
    filter { prefix = "wazuh/alerts/" }
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.wazuh_log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  rule {
    id     = "wazuh-archives-lifecycle"
    status = "Enabled"
    filter { prefix = "wazuh/archives/" }
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.wazuh_log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  rule {
    id     = "vpn-lifecycle"
    status = "Enabled"
    filter { prefix = "vpn/" }
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.wazuh_log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  # ── VPC Flow Log (REJECT만) 365일 ───────────────────────
  rule {
    id     = "flowlogs-lifecycle"
    status = "Enabled"
    filter { prefix = "flowlogs/" }
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.flowlogs_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  # ── WAF 로그 90일 ────────────────────────────────────────
  # WAF는 이미 차단된 트래픽 — 장기 보존 불필요
  rule {
    id     = "waf-lifecycle"
    status = "Enabled"
    filter { prefix = "waf/" }
    expiration { days = var.waf_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  # ── Wazuh DB 백업 7일 ────────────────────────────────────
  # wodle 수집 위치 추적용 .db 파일 — 재생성 가능
  rule {
    id     = "wazuh-db-backup-lifecycle"
    status = "Enabled"
    filter { prefix = "wazuh/db-backup/" }
    expiration { days = var.wazuh_db_backup_retention_days }
    noncurrent_version_expiration { noncurrent_days = 3 }
  }

  # ── Wazuh Indexer 스냅샷 7일 ────────────────────────────
  # alerts/archives/ 에 원본 있으므로 단기 보존
  rule {
    id     = "wazuh-snapshots-lifecycle"
    status = "Enabled"
    filter { prefix = "wazuh/snapshots/" }
    expiration { days = var.wazuh_snapshots_retention_days }
    noncurrent_version_expiration { noncurrent_days = 3 }
  }

  # ── DB 덤프 30일 ─────────────────────────────────────────
  rule {
    id     = "db-dump-lifecycle"
    status = "Enabled"
    filter { prefix = "db-dumps/" }
    expiration { days = var.db_dump_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  # ── GitHub 백업 소스/tfstate 90일 ────────────────────────
  rule {
    id     = "github-backup-source-lifecycle"
    status = "Enabled"
    filter { prefix = "github-backup/source/" }
    expiration { days = var.github_backup_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  rule {
    id     = "github-backup-tfstate-lifecycle"
    status = "Enabled"
    filter { prefix = "github-backup/tfstate/" }
    expiration { days = var.github_backup_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  # ── GitHub 증적 로그 365일 (ISMS-P 2.9.1) ───────────────
  rule {
    id     = "github-backup-logs-lifecycle"
    status = "Enabled"
    filter { prefix = "github-backup/logs/" }
    expiration { days = var.github_backup_log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  # RDS pgaudit 감사 로그 365일 (ISMS-P 2.9.1, 접근기록 1년 보존)- 260607 김강환
  rule {
    id     = "rds-lifecycle"
    status = "Enabled"
    filter { prefix = "rds/" }
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.wazuh_log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
# 온프레미스 감사 로그 365일 (ISMS-P 2.9.1) - 260608 김강환
  rule {
    id     = "onprem-audit-lifecycle"
    status = "Enabled"
    filter { prefix = "onprem/" }
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.wazuh_log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
  # ECS fastapi 감사 로그 365일 (ISMS-P 2.9.1) - 260608 김강환
  rule {
    id     = "ecs-lifecycle"
    status = "Enabled"
    filter { prefix = "ecs/" }
    transition {
      days          = var.wazuh_log_glacier_days
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.wazuh_log_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  # Lambda 로그 365일 보존 후 삭제, 90일 후 Glacier 전환
  # ISMS-P 2.9.1: 감사 로그 1년 보존 의무 - 260610 김강환
  rule {
    id     = "lambda-lifecycle"
    status = "Enabled"
    filter { prefix = "lambda/" }
    transition {
      days          = var.wazuh_log_glacier_days   # 90일 후 Glacier IR 전환
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.wazuh_log_retention_days }          # 365일 후 삭제
    noncurrent_version_expiration { noncurrent_days = 7 }       # 이전 버전 7일 후 삭제
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
      # AWS CloudTrail이 S3 버킷에 로그를 저장할 수 있도록 권한 부여 (20260530, by 김강환)
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
      # GuardDuty가 S3 버킷에 결과를 저장할 수 있도록 권한 부여 (20260530, by 김강환)
      # ap-south-2 opt-in 리전 — guardduty.amazonaws.com 대신 리전별 엔드포인트 사용
      # 공식문서: https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_exportfindings.html
      {
        Sid    = "AllowGuardDutyGetBucketLocation"
        Effect = "Allow"
        Principal = { Service = "guardduty.ap-south-2.amazonaws.com" }
        Action   = "s3:GetBucketLocation"
        Resource = aws_s3_bucket.storage.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            "aws:SourceArn" = "arn:aws:guardduty:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:detector/${data.terraform_remote_state.security.outputs.guardduty_detector_id}"
          }
        }
      },
      {
        Sid    = "AllowGuardDutyPutObject"
        Effect = "Allow"
        Principal = { Service = "guardduty.ap-south-2.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource =  "${aws_s3_bucket.storage.arn}/guardduty/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            "aws:SourceArn"     = "arn:aws:guardduty:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:detector/${data.terraform_remote_state.security.outputs.guardduty_detector_id}"
          }
        }
      },
      {
        Sid    = "DenyGuardDutyUnencrypted"
        Effect = "Deny"
        Principal = { Service = "guardduty.ap-south-2.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/guardduty/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      {
        Sid    = "DenyGuardDutyWrongKMSKey"
        Effect = "Deny"
        Principal = { Service = "guardduty.ap-south-2.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/guardduty/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
          }
        }
      },
      # AWS Flow Logs 권한 예시 (20260530, by 김강환) - VPC Flow Logs → S3 로그 전달용
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

      # 추가: GitHub Actions 백업 권한 (20260530, by 김다정)
      {
        Sid    = "AllowGitHubActionsListBucket"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-github-actions-role"
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
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-github-actions-role"
        }
        Action = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.storage.arn}/github-backup/*"
      },
      {
        Sid    = "AllowFirehoseWAF"
        Effect = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/waf/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      # S3 버킷 정책에 Firehose가 rds/ 쓰는 권한이 없어서 추가 (20260530, by 김강환)
      {
        Sid    = "AllowFirehoseVPN"
        Effect = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/vpn/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowFirehoseRDS"
        Effect = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/rds/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        # Firehose → S3 lambda/ prefix 쓰기 허용
        # Lambda 로그 장기보관용 (ISMS-P 2.9.1) - 260610 김강환
        Sid    = "AllowFirehoseLambda"
        Effect = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/lambda/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },



      # ECS EC2 Vector → S3 쓰기 권한 - 260608 김강환
      {
        Sid    = "AllowECSEC2Vector"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-ecs-ec2-instance-role"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.storage.arn}/ecs/*"
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
              "guardduty.ap-south-2.amazonaws.com",
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





# ─────────────────────────────────────────────────────────
# ALB 액세스 로그 전용 버킷
# ALB 로그는 SSE-KMS 미지원 → SSE-S3만 가능 (AWS 제약)
# ISMS-P 2.9.1: 1년 보존   260602 김강환
# ─────────────────────────────────────────────────────────
resource "aws_s3_bucket" "aws-alb-logs-01" {
  bucket = "aws-k2p-alb-01"

  tags = merge(local.common_tags, {
    Name    = "aws-alb-logs-01"
    Purpose = "ALB-access-log-retention-ISMS-P-2.9.1"
  })
}

resource "aws_s3_bucket_public_access_block" "aws-alb-logs-01" {
  bucket = aws_s3_bucket.aws-alb-logs-01.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ALB 로그는 SSE-KMS 미지원 — SSE-S3 필수
resource "aws_s3_bucket_server_side_encryption_configuration" "aws-alb-logs-01" {
  bucket = aws_s3_bucket.aws-alb-logs-01.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "aws-alb-logs-01" {
  bucket = aws_s3_bucket.aws-alb-logs-01.id

  rule {
    id     = "alb-log-lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 365
    }
  }
}

# ALB 로그 전달 허용 버킷 정책
# logdelivery.elasticloadbalancing.amazonaws.com 서비스 주체 필요
# 공식문서 기준: Resource에 계정 ID 포함 필수

resource "aws_s3_bucket_policy" "aws-alb-logs-01" {
  bucket = aws_s3_bucket.aws-alb-logs-01.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ALBLogDeliveryWrite"
        Effect = "Allow"
        Principal = {
          Service = "logdelivery.elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.aws-alb-logs-01.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "ALBLogDeliveryAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "logdelivery.elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.aws-alb-logs-01.arn
      },
      {
        Sid       = "DenyNonSSL"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.aws-alb-logs-01.arn,
          "${aws_s3_bucket.aws-alb-logs-01.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
          StringNotEqualsIfExists = {
            "aws:PrincipalServiceNamesList" = [
              "logdelivery.elasticloadbalancing.amazonaws.com"
            ]
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.aws-alb-logs-01]
}