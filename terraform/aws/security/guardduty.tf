
# GuardDuty Detector
resource "aws_guardduty_detector" "aws-gd" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Project = "msp-hospital"
    ISMS    = "2.12.4"
  }
}

# S3 버킷 정책 (GuardDuty가 쓸 수 있도록)
resource "aws_s3_bucket_policy" "aws-s3-policy-gd" {
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
resource "aws_guardduty_publishing_destination" "aws-gd-s3" {
  detector_id     = aws_guardduty_detector.aws-gd.id
  destination_arn = "arn:aws:s3:::aws-k2p-storage-01"
  kms_key_arn     =  data.terraform_remote_state.kms.outputs.s3_kms_key_arn

  depends_on = [aws_s3_bucket_policy.aws-s3-policy-gd]
}

