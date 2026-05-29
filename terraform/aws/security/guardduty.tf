# KMS 키 (GuardDuty S3 내보내기 암호화 필수)
resource "aws_kms_key" "aws-kms-guardduty" {
  description             = "GuardDuty findings S3 export"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow GuardDuty to use the key"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
        }
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = "*"
      }
    ]
  })
}

# GuardDuty Detector
resource "aws_guardduty_detector" "aws-guardduty-main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Project = "msp-hospital"
    ISMS    = "2.12.4"
  }
}

# S3 버킷 정책 (GuardDuty가 쓸 수 있도록)
resource "aws_s3_bucket_policy" "aws-s3-policy-guardduty" {
  bucket = "aws-k2p-storage-01"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowGuardDutygetBucketLocation"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
        }
        Action   = "s3:GetBucketLocation"
        Resource = "arn:aws:s3:::aws-k2p-storage-01"
      },
      {
        Sid    = "AllowGuardDutyPutObject"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::aws-k2p-storage-01/guardduty/*"
      }
    ]
  })
}

# GuardDuty → S3 직접 내보내기
resource "aws_guardduty_publishing_destination" "aws-guardduty-s3" {
  detector_id     = aws_guardduty_detector.aws-guardduty-main.id
  destination_arn = "arn:aws:s3:::aws-k2p-storage-01"
  kms_key_arn     = aws_kms_key.aws-kms-guardduty.arn

  depends_on = [aws_s3_bucket_policy.aws-s3-policy-guardduty]
}

