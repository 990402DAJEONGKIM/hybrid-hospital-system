# CloudTrail
resource "aws_cloudtrail" "aws-cloudtrail-main" {
  name                          = "aws-cloudtrail-main"
  s3_bucket_name                = aws_s3_bucket.aws-s3-cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = false   # ap-south-2 단일 리전
  enable_log_file_validation    = true    # 무결성 검증 (ISMS-P 필수)
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.aws-cloudwatch-cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.aws-iam-role-cloudtrail-cw.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::aws-k2p-storage-01/"]
    }
  }

  tags = {
    Project = "msp-hospital"
    ISMS    = "2.9.4"
  }
}

resource "aws_s3_bucket" "aws-s3-cloudtrail" {
  bucket        = "aws-k2p-cloudtrail-logs"
  force_destroy = false
}

resource "aws_s3_bucket_policy" "aws-s3-policy-cloudtrail" {
  bucket = aws_s3_bucket.aws-s3-cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.aws-s3-cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.aws-s3-cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "aws-s3-lifecycle-cloudtrail" {
  bucket = aws_s3_bucket.aws-s3-cloudtrail.id

  rule {
    id     = "glacier-transition"
    status = "Enabled"
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 365
    }
  }
}

resource "aws_cloudwatch_log_group" "aws-cloudwatch-cloudtrail" {
  name              = "/aws/cloudtrail/main"
  retention_in_days = 90
}

resource "aws_iam_role" "aws-iam-role-cloudtrail-cw" {
  name = "aws-iam-role-cloudtrail-cw"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "aws-iam-policy-cloudtrail-cw" {
  name = "aws-iam-policy-cloudtrail-cw"
  role = aws_iam_role.aws-iam-role-cloudtrail-cw.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.aws-cloudwatch-cloudtrail.arn}:*"
    }]
  })
}
