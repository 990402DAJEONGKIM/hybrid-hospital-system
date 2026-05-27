# 기존 TC-aws-S3에서 관리하는 리소스들을 data source로 참조

data "aws_caller_identity" "current" {}

data "aws_kms_key" "s3" {
  key_id = "alias/aws-kms-s3-01"
}

data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_db_instance" "aurora" {
  db_instance_identifier = var.rds_instance_id
}

data "aws_s3_bucket" "storage" {
  bucket = var.s3_bucket_name
}
data "aws_kms_key" "secretsmanager" {
  key_id = "alias/aws-kms-secretsmanager-01"
}
data "aws_kms_key" "secretsmanager" {
  key_id = "alias/aws-kms-sm-01"
}