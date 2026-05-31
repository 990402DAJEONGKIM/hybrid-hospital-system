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