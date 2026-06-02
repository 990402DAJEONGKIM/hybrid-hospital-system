##############################################################
# main.tf
# 온프레미스 ↔ AWS Site-to-Site VPN 구성
# 리전: ap-south-2 (Hyderabad)
##############################################################

##############################################################
# Data Sources — 기존 VPC, 라우팅 테이블 참조
##############################################################

data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}

data "aws_route_table" "pub" {
  filter {
    name   = "tag:Name"
    values = ["aws-rt-pub-01"]
  }
}

data "aws_route_table" "app" {
  filter {
    name   = "tag:Name"
    values = ["aws-rt-app-01"]
  }
}

data "aws_route_table" "db" {
  filter {
    name   = "tag:Name"
    values = ["aws-rt-db-01"]
  }
}

data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────
# KMS 키 ARN 참조 (TC-aws-KMS 워크스페이스 output)
# Firehose가 S3에 저장할 때 SSE-KMS 암호화에 필요
# ─────────────────────────────────────────────────────────
data "terraform_remote_state" "aws-kms" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-KMS" }
  }
}

##############################################################
# Customer Gateway — 온프레미스 공인 IP 등록
##############################################################

resource "aws_customer_gateway" "main" {
  bgp_asn    = 65000
  ip_address = var.onprem_public_ip
  type       = "ipsec.1"

  tags = {
    Name = "aws-cgw-01"
  }
}

##############################################################
# Virtual Private Gateway — AWS 측 VPN 엔드포인트
##############################################################

resource "aws_vpn_gateway" "main" {
  vpc_id = data.aws_vpc.main.id

  tags = {
    Name = "aws-vgw-01"
  }
}

##############################################################
# VPN Connection — Site-to-Site VPN (정적 라우팅)
##############################################################

resource "aws_vpn_connection" "main" {
  customer_gateway_id = aws_customer_gateway.main.id
  vpn_gateway_id      = aws_vpn_gateway.main.id
  type                = "ipsec.1"
  static_routes_only  = true


  tunnel1_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.aws-cwl-vpn-onprem-logs.arn
      log_output_format = "json"
    }
  }
  tunnel2_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.aws-cwl-vpn-onprem-logs.arn
      log_output_format = "json"
    }
  }
  depends_on = [aws_cloudwatch_log_resource_policy.aws-cwl-policy-vpn-onprem]
  tags = {
    Name = "aws-vpn-01"
  }
}

##############################################################
# VPN 정적 라우트 — 온프레미스 대역 등록 (핵심)
##############################################################

resource "aws_vpn_connection_route" "onprem" {
  vpn_connection_id      = aws_vpn_connection.main.id
  destination_cidr_block = var.onprem_cidr
}

##############################################################
# 라우팅 테이블 — 온프레미스 대역 경로 추가
##############################################################

resource "aws_route" "pub_to_onprem" {
  route_table_id         = data.aws_route_table.pub.id
  destination_cidr_block = var.onprem_cidr
  gateway_id             = aws_vpn_gateway.main.id
}

resource "aws_route" "app_to_onprem" {
  route_table_id         = data.aws_route_table.app.id
  destination_cidr_block = var.onprem_cidr
  gateway_id             = aws_vpn_gateway.main.id
}

resource "aws_route" "db_to_onprem" {
  route_table_id         = data.aws_route_table.db.id
  destination_cidr_block = var.onprem_cidr
  gateway_id             = aws_vpn_gateway.main.id
}


resource "aws_cloudwatch_log_group" "aws-cwl-vpn-onprem-logs" {
  name              = "/aws/vendedlogs/vpn/aws-vpn-01"
  retention_in_days = 365
  tags = { Name = "aws-cwl-vpn-onprem-logs" }
}


# ─────────────────────────────────────────────────────────
# Firehose IAM Role — S3 쓰기 + KMS 암호화 권한
# ISMS-P 2.5.3 최소 권한 원칙
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "aws-firehose-vpn-role" {
  name = "aws-firehose-vpn-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "aws-firehose-vpn-role" }
}

resource "aws_iam_role_policy" "aws-firehose-vpn-policy" {
  name = "aws-firehose-vpn-policy"
  role = aws_iam_role.aws-firehose-vpn-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # S3 버킷에 로그 파일 저장 권한
        Sid    = "S3Write"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*"
        ]
      },
      {
        # KMS 키로 S3 저장 파일 암호화 (ISMS-P 2.7.1)
        Sid    = "KMSEncrypt"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.terraform_remote_state.aws-kms.outputs.s3_kms_key_arn
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────
# Firehose — 온프레미스 VPN 로그 → S3
# CloudWatch에서 받은 VPN 터널 이벤트를 S3에 장기보관
# prefix: vpn/onprem/ (S3 버킷 정책 AllowFirehoseVPN과 일치)
# buffering: 5MB 또는 5분마다 S3에 flush
# ─────────────────────────────────────────────────────────
resource "aws_kinesis_firehose_delivery_stream" "aws-firehose-vpn-onprem-01" {
  name        = "aws-firehose-vpn-onprem-01"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.aws-firehose-vpn-role.arn
    bucket_arn          = "arn:aws:s3:::aws-k2p-storage-01"
    prefix              = "vpn/onprem/"
    error_output_prefix = "vpn/onprem/errors/"
    buffering_size      = 5
    buffering_interval  = 300
    kms_key_arn         = data.terraform_remote_state.aws-kms.outputs.s3_kms_key_arn
  }

  tags = { Name = "aws-firehose-vpn-onprem-01" }
}

# ─────────────────────────────────────────────────────────
# CloudWatch → Firehose 전달 IAM Role
# CloudWatch Logs가 Firehose에 로그를 푸시할 때 사용하는 Role
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "aws-cwl-firehose-vpn-role" {
  name = "aws-cwl-firehose-vpn-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.ap-south-2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "aws-cwl-firehose-vpn-role" }
}

resource "aws_iam_role_policy" "aws-cwl-firehose-vpn-policy" {
  name = "aws-cwl-firehose-vpn-policy"
  role = aws_iam_role.aws-cwl-firehose-vpn-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # CloudWatch가 Firehose에 레코드를 전송할 수 있는 권한
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = aws_kinesis_firehose_delivery_stream.aws-firehose-vpn-onprem-01.arn
    }]
  })
}

# ─────────────────────────────────────────────────────────
# CloudWatch Subscription Filter — VPN 로그 → Firehose
# /aws/vendedlogs/vpn/aws-vpn-01 로그그룹의 모든 이벤트를
# Firehose로 실시간 전달 (filter_pattern="" = 전체 전달)
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_subscription_filter" "aws-cwl-vpn-onprem-to-s3" {
  name            = "aws-cwl-vpn-onprem-to-s3"
  log_group_name  = aws_cloudwatch_log_group.aws-cwl-vpn-onprem-logs.name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.aws-firehose-vpn-onprem-01.arn
  role_arn        = aws_iam_role.aws-cwl-firehose-vpn-role.arn
}


# VPN 로그 CloudWatch 전송용 리소스 정책
# delivery.logs.amazonaws.com이 Log Group에 쓸 수 있도록 허용
resource "aws_cloudwatch_log_resource_policy" "aws-cwl-policy-vpn-onprem" {
  policy_name = "aws-cwl-policy-vpn-onprem"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowVPNLogDelivery"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vendedlogs/vpn/aws-vpn-01:*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpn-connection/*"
          }
        }
      }
    ]
  })
}