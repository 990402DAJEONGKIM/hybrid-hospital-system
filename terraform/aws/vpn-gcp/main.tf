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
#test
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

  tags = {
    Name = "aws-vpn-gcp"
  }
}

# ── 정적 라우트 — GCP 대역 ────────────────────────────────────

resource "aws_vpn_connection_route" "gcp" {
  vpn_connection_id      = aws_vpn_connection.gcp.id
  destination_cidr_block = var.gcp_cidr
}

# ── 라우팅 테이블 — DB 서브넷만 GCP 허용 (최소 권한) ──────────
# pglogical 복제는 RDS → Cloud SQL 단방향이므로 DB 서브넷만 필요

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
