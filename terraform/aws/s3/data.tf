data "aws_kms_key" "s3" {
  key_id = "alias/aws-kms-s3-01"
}

data "aws_caller_identity" "current" {}
