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
