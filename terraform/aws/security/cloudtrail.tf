resource "aws_cloudtrail" "aws-ct-01" {
  name                          = "aws-cloudtrail-main"
  s3_bucket_name                = "aws-k2p-storage-01"
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.aws-cwl-ct.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.aws-iam-role-ct-cw.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

  }

  tags = {
    Project = "msp-hospital"
    ISMS    = "2.9.4"
  }
}

resource "aws_cloudwatch_log_group" "aws-cwl-ct" {
  name              = "/aws/cloudtrail/main"
  retention_in_days = 90
}

resource "aws_iam_role" "aws-iam-role-ct-cw" {
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

resource "aws_iam_role_policy" "aws-iam-policy-ct-cw" {
  name = "aws-iam-policy-cloudtrail-cw"
  role = aws_iam_role.aws-iam-role-ct-cw.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.aws-cwl-ct.arn}:*"
    }]
  })
}