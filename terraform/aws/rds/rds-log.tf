# rds-log-archive.tf - 260607 김강환
# RDS pgaudit 로그 S3 장기보관 (ISMS-P 2.9.1)
# 경로: RDS → CloudWatch Logs(30일) → Subscription Filter → Firehose → S3(rds/, 장기보관)
# VPN 로그 아카이브 패턴(aws-firehose-vpn-*)과 동일 구조

# ── Firehose IAM Role (S3 쓰기 + KMS) ────────────────────
resource "aws_iam_role" "aws-firehose-rds-role" {
  name = "aws-firehose-rds-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "aws-firehose-rds-role" }
}

resource "aws_iam_role_policy" "aws-firehose-rds-policy" {
  name = "aws-firehose-rds-policy"
  role = aws_iam_role.aws-firehose-rds-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Write"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*"
        ]
      },
      {
        Sid    = "KMSEncrypt"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.aws_kms_key.s3.arn
      }
    ]
  })
}

# ── Firehose — RDS pgaudit 로그 → S3 (prefix: rds/) ──────
resource "aws_kinesis_firehose_delivery_stream" "aws-firehose-rds-01" {
  name        = "aws-firehose-rds-01"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.aws-firehose-rds-role.arn
    bucket_arn          = "arn:aws:s3:::aws-k2p-storage-01"
    prefix              = "rds/"
    error_output_prefix = "rds/errors/"
    buffering_size      = 5
    buffering_interval  = 300
    kms_key_arn         = data.aws_kms_key.s3.arn
  }

  tags = { Name = "aws-firehose-rds-01" }
}

# ── CloudWatch → Firehose 전달 IAM Role ──────────────────
resource "aws_iam_role" "aws-cwl-firehose-rds-role" {
  name = "aws-cwl-firehose-rds-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.ap-south-2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "aws-cwl-firehose-rds-role" }
}

resource "aws_iam_role_policy" "aws-cwl-firehose-rds-policy" {
  name = "aws-cwl-firehose-rds-policy"
  role = aws_iam_role.aws-cwl-firehose-rds-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = aws_kinesis_firehose_delivery_stream.aws-firehose-rds-01.arn
    }]
  })
}

# ── Subscription Filter — RDS 로그그룹 → Firehose ─────────
# filter_pattern="" = 전체 전달
resource "aws_cloudwatch_log_subscription_filter" "aws-cwl-rds-to-s3" {
  name            = "aws-cwl-rds-to-s3"
  log_group_name  = aws_cloudwatch_log_group.aws-cwl-rds-postgresql-01.name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.aws-firehose-rds-01.arn
  role_arn        = aws_iam_role.aws-cwl-firehose-rds-role.arn
}