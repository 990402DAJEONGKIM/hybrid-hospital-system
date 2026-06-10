# lambda_logs.tf - 260610 김강환
# Lambda 로그 S3 장기보관 (ISMS-P 2.9.1)
# 경로: Lambda → CloudWatch Logs → Subscription Filter → Firehose → S3(lambda/, 장기보관)
# RDS 로그 아카이브 패턴(aws-firehose-rds-*)과 동일 구조

# ── Firehose IAM Role (S3 쓰기 + KMS) ────────────────────
resource "aws_iam_role" "aws-firehose-lambda-role" {
  name = "aws-firehose-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "aws-firehose-lambda-role" }
}

resource "aws_iam_role_policy" "aws-firehose-lambda-policy" {
  name = "aws-firehose-lambda-policy"
  role = aws_iam_role.aws-firehose-lambda-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Firehose → S3 lambda/ prefix 쓰기 권한
        Sid    = "S3Write"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*"
        ]
      },
      {
        # S3 KMS 암호화/복호화 (ISMS-P 2.7.1)
        Sid    = "KMSEncrypt"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
      }
    ]
  })
}

# ── Firehose — Lambda 로그 → S3 (prefix: lambda/) ─────────
# buffering_size=5MB, buffering_interval=300초 — RDS 패턴과 동일
# prefix에 날짜 포함 → S3 파티셔닝으로 조회 성능 향상
resource "aws_kinesis_firehose_delivery_stream" "aws-firehose-lambda-01" {
  name        = "aws-firehose-lambda-01"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.aws-firehose-lambda-role.arn
    bucket_arn          = "arn:aws:s3:::aws-k2p-storage-01"
    prefix              = "lambda/"
    error_output_prefix = "lambda/errors/"
    buffering_size      = 5
    buffering_interval  = 300
    kms_key_arn         = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
  }

  tags = { Name = "aws-firehose-lambda-01" }
}

# ── CloudWatch Logs → Firehose 전달 IAM Role ─────────────
# CloudWatch Logs가 Firehose에 PutRecord 호출 가능하도록 권한 부여
resource "aws_iam_role" "aws-cwl-firehose-lambda-role" {
  name = "aws-cwl-firehose-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      # ap-south-2 리전 CloudWatch Logs 서비스가 역할 Assume
      Principal = { Service = "logs.ap-south-2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "aws-cwl-firehose-lambda-role" }
}

resource "aws_iam_role_policy" "aws-cwl-firehose-lambda-policy" {
  name = "aws-cwl-firehose-lambda-policy"
  role = aws_iam_role.aws-cwl-firehose-lambda-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = aws_kinesis_firehose_delivery_stream.aws-firehose-lambda-01.arn
    }]
  })
}

# ── Subscription Filter — Lambda 20개 로그그룹 → Firehose ─
# for_each로 20개 로그그룹에 동일한 필터 적용
# filter_pattern="" = 전체 전달 (에러 필터링은 Wazuh 룰에서 처리)
locals {
  lambda_log_groups = [
    "/aws/lambda/aws-lambda-dump",
    "/aws/lambda/mzclinic-keycloak-db-rotator",
    "/aws/lambda/aws-wazuh-lambda-agent-cleanup",
    "/aws/lambda/aws-wazuh-report-fn-01",
    "/aws/lambda/aws-lambda-jwt-rotator",
    "/aws/lambda/aws-lambda-cost-monthly-report",
    "/aws/lambda/aws-wazuh-lambda-indexer-recovery",
    "/aws/lambda/aws-lambda-vault-rotator",
    "/aws/lambda/aws-lambda-ecs-db-rotator",
    "/aws/lambda/aws-lambda-cost-gcp-collector",
    "/aws/lambda/aws-lambda-cost-to-kb",
    "/aws/lambda/aws-lambda-cost-chat",
    "/aws/lambda/aws-wazuh-lambda-recovery",
    "/aws/lambda/aws-lambda-cost-anomaly",
    "/aws/lambda/aws-wazuh-lambda-slack-notify",
    "/aws/lambda/aws-lambda-cost-aws-collector",
    "/aws/lambda/aws-lambda-rotation",
    "/aws/lambda/aws-lambda-cost-onprem-calc",
    "/aws/lambda/aws-lambda-cost-dashboard",
    "/aws/lambda/aws-lambda-ecs-redeployer",
  ]
}

resource "aws_cloudwatch_log_subscription_filter" "aws-cwl-lambda-to-s3" {
  for_each = toset(local.lambda_log_groups)

  # 리소스 이름에 슬래시 포함 불가 — replace로 하이픈 치환
  name            = "aws-cwl-lambda-to-s3-${replace(each.key, "/", "-")}"
  log_group_name  = each.key
  filter_pattern  = ""   # 전체 전달, 에러 필터링은 Wazuh 룰에서 처리
  destination_arn = aws_kinesis_firehose_delivery_stream.aws-firehose-lambda-01.arn
  role_arn        = aws_iam_role.aws-cwl-firehose-lambda-role.arn
}