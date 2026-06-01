##############################################################
# main.tf
# AWS <-> GCP Site-to-Site VPN 구성 (AWS 측)
# 기존 VGW(aws-vgw-01) 재사용
#
# ISMS-P 준수 사항:
#   - IKEv2 강제
#   - PSK 직접 지정 (TFC 변수로 관리)
#   - 라우팅: DB 서브넷만 GCP 접근 허용
##############################################################

# ── 기존 리소스 참조 ─────────────────────────────────────────

data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}

data "aws_vpn_gateway" "main" {
  filter {
    name   = "tag:Name"
    values = ["aws-vgw-01"]
  }
}

data "aws_route_table" "db" {
  filter {
    name   = "tag:Name"
    values = ["aws-rt-db-01"]
  }
}

# ── Customer Gateway — GCP VPN IP 등록 ───────────────────────

resource "aws_customer_gateway" "gcp" {
  bgp_asn    = 65001
  ip_address = var.gcp_vpn_ip
  type       = "ipsec.1"

  tags = {
    Name = "aws-cgw-gcp"
  }
    lifecycle {
    create_before_destroy = true
  }
}


# ─────────────────────────────────────────────────────────
# KMS 키 ARN 참조 (TC-aws-KMS 워크스페이스 output)
# ─────────────────────────────────────────────────────────
data "terraform_remote_state" "aws-kms" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-KMS" }
  }
}

# ── VPN Connection (IKEv2 강제, PSK 직접 지정) ───────────────

resource "aws_vpn_connection" "gcp" {
  customer_gateway_id = aws_customer_gateway.gcp.id
  vpn_gateway_id      = data.aws_vpn_gateway.main.id
  type                = "ipsec.1"
  static_routes_only  = true

  # ISMS-P: IKEv2 강제
  tunnel1_ike_versions = ["ikev2"]
  tunnel2_ike_versions = ["ikev2"]

  # ISMS-P: PSK 직접 지정 (TFC sensitive 변수)
  tunnel1_preshared_key = var.tunnel1_psk
  tunnel2_preshared_key = var.tunnel2_psk

  # ISMS-P: 강력한 암호화 알고리즘
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_dh_group_numbers      = [14]

  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel2_phase2_dh_group_numbers      = [14]

  tunnel1_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.aws-cwl-vpn-gcp-logs.arn
      log_output_format = "json"
    }
  }
  tunnel2_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.aws-cwl-vpn-gcp-logs.arn
      log_output_format = "json"
    }
  }

  tags = {
    Name = "aws-vpn-gcp"
  }
}

# ── 정적 라우트 — GCP VPC 서브넷 대역 ────────────────────────

resource "aws_vpn_connection_route" "gcp" {
  vpn_connection_id      = aws_vpn_connection.gcp.id
  destination_cidr_block = var.gcp_cidr
}

# GCP Cloud SQL PSA 대역 VPN 라우트 (Cloud SQL 직접 연결용)
resource "aws_vpn_connection_route" "gcp_psa" {
  vpn_connection_id      = aws_vpn_connection.gcp.id
  destination_cidr_block = var.gcp_psa_cidr
}

# GCP Cloud Functions VPC Connector 대역 VPN 라우트
# (gcp-fn-cloudsql-rotation → Aurora 비밀번호 로테이션용)
# 2026-05-27 수동 추가분 IaC화
resource "aws_vpn_connection_route" "gcp_cloudfn" {
  vpn_connection_id      = aws_vpn_connection.gcp.id
  destination_cidr_block = var.gcp_cloudfn_cidr
}

# ── 라우팅 테이블 — DB 서브넷 ─────────────────────────────────

resource "aws_route" "db_to_gcp" {
  route_table_id         = data.aws_route_table.db.id
  destination_cidr_block = var.gcp_cidr
  gateway_id             = data.aws_vpn_gateway.main.id
}

# GCP Cloud SQL PSA 대역 라우트 (pglogical 복제용)
resource "aws_route" "db_to_gcp_psa" {
  route_table_id         = data.aws_route_table.db.id
  destination_cidr_block = var.gcp_psa_cidr
  gateway_id             = data.aws_vpn_gateway.main.id
}

# GCP Cloud Functions VPC Connector 라우팅 테이블 등록
resource "aws_route" "db_to_gcp_cloudfn" {
  route_table_id         = data.aws_route_table.db.id
  destination_cidr_block = var.gcp_cloudfn_cidr
  gateway_id             = data.aws_vpn_gateway.main.id
}


# 260531 김강환
# ── 라우팅 테이블 — App 서브넷 (Wazuh Agent → GCP 통신용) ────
# app subnet은 Wazuh Agent가 위치한 곳으로, GCP VPN을 통해 Wazuh Manager와 통신할 수 있도록 라우트 추가
data "aws_route_table" "app" {
  filter {
    name   = "tag:Name"
    values = ["aws-rt-app-01"]
  }
}

resource "aws_route" "app_to_gcp" {
  route_table_id         = data.aws_route_table.app.id
  destination_cidr_block = var.gcp_cidr
  gateway_id             = data.aws_vpn_gateway.main.id
}


resource "aws_cloudwatch_log_group" "aws-cwl-vpn-gcp-logs" {
  name              = "/aws/vendedlogs/vpn/aws-vpn-gcp"
  retention_in_days = 365
  tags = { Name = "aws-cwl-vpn-gcp-logs" }
}


# ─────────────────────────────────────────────────────────
# Firehose IAM Role — S3 쓰기 + KMS 암호화 권한
# TC-VPN과 별도 워크스페이스라 Role 분리 필요
# ISMS-P 2.5.3 최소 권한 원칙
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "aws-firehose-vpn-gcp-role" {
  name = "aws-firehose-vpn-gcp-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "aws-firehose-vpn-gcp-role" }
}

resource "aws_iam_role_policy" "aws-firehose-vpn-gcp-policy" {
  name = "aws-firehose-vpn-gcp-policy"
  role = aws_iam_role.aws-firehose-vpn-gcp-role.id
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
# Firehose — GCP VPN 로그 → S3
# CloudWatch에서 받은 GCP 터널 이벤트를 S3에 장기보관
# prefix: vpn/gcp/ (S3 버킷 정책 AllowFirehoseVPN과 일치)
# ─────────────────────────────────────────────────────────
resource "aws_kinesis_firehose_delivery_stream" "aws-firehose-vpn-gcp-01" {
  name        = "aws-firehose-vpn-gcp-01"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.aws-firehose-vpn-gcp-role.arn
    bucket_arn          = "arn:aws:s3:::aws-k2p-storage-01"
    prefix              = "vpn/gcp/"
    error_output_prefix = "vpn/gcp/errors/"
    buffering_size      = 5
    buffering_interval  = 300
    kms_key_arn         = data.terraform_remote_state.aws-kms.outputs.s3_kms_key_arn
  }

  tags = { Name = "aws-firehose-vpn-gcp-01" }
}

# ─────────────────────────────────────────────────────────
# CloudWatch → Firehose 전달 IAM Role
# CloudWatch Logs가 Firehose에 로그를 푸시할 때 사용하는 Role
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "aws-cwl-firehose-vpn-gcp-role" {
  name = "aws-cwl-firehose-vpn-gcp-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.ap-south-2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "aws-cwl-firehose-vpn-gcp-role" }
}

resource "aws_iam_role_policy" "aws-cwl-firehose-vpn-gcp-policy" {
  name = "aws-cwl-firehose-vpn-gcp-policy"
  role = aws_iam_role.aws-cwl-firehose-vpn-gcp-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # CloudWatch가 Firehose에 레코드를 전송할 수 있는 권한
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = aws_kinesis_firehose_delivery_stream.aws-firehose-vpn-gcp-01.arn
    }]
  })
}

# ─────────────────────────────────────────────────────────
# CloudWatch Subscription Filter — GCP VPN 로그 → Firehose
# /aws/vendedlogs/vpn/aws-vpn-gcp 로그그룹의 모든 이벤트를
# Firehose로 실시간 전달 (filter_pattern="" = 전체 전달)
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_subscription_filter" "aws-cwl-vpn-gcp-to-s3" {
  name            = "aws-cwl-vpn-gcp-to-s3"
  log_group_name  = aws_cloudwatch_log_group.aws-cwl-vpn-gcp-logs.name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.aws-firehose-vpn-gcp-01.arn
  role_arn        = aws_iam_role.aws-cwl-firehose-vpn-gcp-role.arn
}