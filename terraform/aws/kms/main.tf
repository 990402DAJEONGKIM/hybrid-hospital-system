# =========================================================
# KMS — 고객 관리형 키 (CMK)
# ISMS-P 2.7.1: 암호키 관리 (생성·교체·폐기 정책 수립)
#
# 키 분리 전략:
#   - rds   : postgresql DB 저장 데이터 암호화
#   - ebs   : EC2 EBS 볼륨 암호화 (ECS EC2 노드)
#   - s3    : S3 버킷 암호화 (로그, 정적 파일, 백업)
#   - sm    : Secrets Manager 암호화 (DB 자격증명 등)
# =========================================================

# ─────────────────────────────────────────────────────────
# 공통 인프라 정보 동적 참조 (추가된 부분 ⭐️)
# ─────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {} # 현재 실행 중인 AWS 계정 ID를 동적으로 가져옴
data "aws_region" "current" {}          # 현재 배포 중인 AWS 리전 정보를 동적으로 가져옴


# ─────────────────────────────────────────────────────────
# 공통 키 정책 (루트 계정 전체 권한 + 키 관리자만 관리 가능)
# ─────────────────────────────────────────────────────────
locals {
  key_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        # Auto Scaling이 CMK로 암호화된 EBS 볼륨을 생성하기 위한 권한
        Sid    = "AllowAutoScalingServiceRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        # Auto Scaling → EC2에 키 사용 권한 위임 (EBS 암호화 필수)
        Sid    = "AllowAutoScalingCreateGrant"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
        }
        Action   = ["kms:CreateGrant"]
        Resource = "*"
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      },
      {
        # ECS 태스크 실행 역할 — Secrets Manager 시크릿 복호화
        Sid    = "AllowECSTaskExecutionRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-ecs-task-execution-role"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
      }
    ]
  })
  # S3 키 전용 정책
  # Firehose가 WAF 로그를 S3에 저장할 때 SSE-KMS 암호화에 필요
  # RDS/EBS/SM/ECR 키에는 Firehose 권한 불필요 → 최소 권한 원칙 준수 (ISMS-P 2.5.3)
  s3_key_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      jsondecode(local.key_policy).Statement,
      [
        {
        Sid    = "AllowFirehoseForS3Only"
        Effect = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowGuardDuty"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
        }
        Action   = ["kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            "aws:SourceArn" = "arn:aws:guardduty:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:detector/692bc5874baa41429fc7396c82c862c6"
          }
        }
      }]
    )
  })
}






# ─────────────────────────────────────────────────────────
# 1. RDS 암호화 키
#    PostgreSQL 인스턴스 저장 데이터 (at-rest) 암호화
#    개인정보보호법 제29조, ISMS-P 2.7.1
# ─────────────────────────────────────────────────────────
resource "aws_kms_key" "rds" {
  description             = "Hospital RDS PostgreSQL 저장 데이터 암호화 키"
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
  name          = "alias/aws-kms-rds-01"
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
  name          = "alias/aws-kms-ebs-01"
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
  policy                  = local.s3_key_policy

  tags = {
    Name    = "aws-kms-s3-01"
    Purpose = "s3-encryption"
  }
}

resource "aws_kms_alias" "s3" {
  name          = "alias/aws-kms-s3-01"
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
  name          = "alias/aws-kms-sm-01"
  target_key_id = aws_kms_key.secretsmanager.key_id
}


# ─────────────────────────────────────────────────────────
# 5. ECR 암호화 키
#    컨테이너 이미지 저장 데이터 암호화
#    ISMS-P 2.7.1
# ─────────────────────────────────────────────────────────
resource "aws_kms_key" "ecr" {
  description             = "Hospital ECR 컨테이너 이미지 암호화 키"
  enable_key_rotation     = true
  rotation_period_in_days = var.key_rotation_period_days
  deletion_window_in_days = var.deletion_window_days
  policy                  = local.key_policy

  tags = {
    Name    = "aws-kms-ecr-01"
    Purpose = "ecr-encryption"
  }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/aws-kms-ecr-01"
  target_key_id = aws_kms_key.ecr.key_id
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