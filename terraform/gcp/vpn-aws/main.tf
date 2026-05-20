##############################################################
# main.tf
# AWS <-> GCP Site-to-Site VPN 구성 (GCP 측)
# 기존 gcp-vpc 재사용
#
# ISMS-P 준수 사항:
#   - IKEv2 강제
#   - PSK TFC sensitive 변수로 관리
#   - 방화벽: AWS DB 서브넷만 허용 (최소 권한)
#   - ICMP: 개발환경 한정 허용 (운영 전 제거)
##############################################################
#테스트용으로 잠깐 전환
# ── 기존 리소스 참조 ─────────────────────────────────────────

data "google_compute_network" "main" {
  name = var.gcp_network
}

data "google_compute_subnetwork" "main" {
  name   = var.gcp_subnet
  region = var.region
}

# ── Cloud VPN Gateway ─────────────────────────────────────────

resource "google_compute_vpn_gateway" "aws" {
  name    = "gcp-vpn-gw-aws"
  network = data.google_compute_network.main.id
  region  = var.region
}

# ── 외부 IP ───────────────────────────────────────────────────

resource "google_compute_address" "vpn_ip" {
  name   = "gcp-vpn-ip-aws"
  region = var.region
}

# ── Forwarding Rules ──────────────────────────────────────────

resource "google_compute_forwarding_rule" "esp" {
  name        = "gcp-vpn-rule-esp"
  region      = var.region
  ip_protocol = "ESP"
  ip_address  = google_compute_address.vpn_ip.address
  target      = google_compute_vpn_gateway.aws.self_link
}

resource "google_compute_forwarding_rule" "udp500" {
  name        = "gcp-vpn-rule-udp500"
  region      = var.region
  ip_protocol = "UDP"
  port_range  = "500"
  ip_address  = google_compute_address.vpn_ip.address
  target      = google_compute_vpn_gateway.aws.self_link
}

resource "google_compute_forwarding_rule" "udp4500" {
  name        = "gcp-vpn-rule-udp4500"
  region      = var.region
  ip_protocol = "UDP"
  port_range  = "4500"
  ip_address  = google_compute_address.vpn_ip.address
  target      = google_compute_vpn_gateway.aws.self_link
}

# ── VPN Tunnel 1 (IKEv2, AES256) ─────────────────────────────

resource "google_compute_vpn_tunnel" "tunnel1" {
  name               = "gcp-vpn-tunnel-aws-1"
  region             = var.region
  peer_ip            = var.aws_tunnel1_ip
  shared_secret      = var.aws_tunnel1_psk
  target_vpn_gateway = google_compute_vpn_gateway.aws.self_link
  ike_version        = 2  # ISMS-P: IKEv2 강제

  local_traffic_selector  = ["0.0.0.0/0"]
  remote_traffic_selector = ["0.0.0.0/0"]

  depends_on = [
    google_compute_forwarding_rule.esp,
    google_compute_forwarding_rule.udp500,
    google_compute_forwarding_rule.udp4500,
  ]
}

# ── VPN Tunnel 2 (IKEv2, AES256) ─────────────────────────────

resource "google_compute_vpn_tunnel" "tunnel2" {
  name               = "gcp-vpn-tunnel-aws-2"
  region             = var.region
  peer_ip            = var.aws_tunnel2_ip
  shared_secret      = var.aws_tunnel2_psk
  target_vpn_gateway = google_compute_vpn_gateway.aws.self_link
  ike_version        = 2  # ISMS-P: IKEv2 강제

  local_traffic_selector  = ["0.0.0.0/0"]
  remote_traffic_selector = ["0.0.0.0/0"]

  depends_on = [
    google_compute_forwarding_rule.esp,
    google_compute_forwarding_rule.udp500,
    google_compute_forwarding_rule.udp4500,
  ]
}

# ── 정적 라우트 — AWS DB 서브넷 대역 ─────────────────────────

resource "google_compute_route" "aws_tunnel1" {
  name                = "gcp-route-aws-tunnel1"
  network             = data.google_compute_network.main.name
  dest_range          = "10.0.0.0/16"
  priority            = 1000
  next_hop_vpn_tunnel = google_compute_vpn_tunnel.tunnel1.self_link
}

resource "google_compute_route" "aws_tunnel2" {
  name                = "gcp-route-aws-tunnel2"
  network             = data.google_compute_network.main.name
  dest_range          = "10.0.0.0/16"
  priority            = 2000
  next_hop_vpn_tunnel = google_compute_vpn_tunnel.tunnel2.self_link
}

# ── 방화벽 — AWS DB 서브넷만 허용 (최소 권한) ─────────────────

resource "google_compute_firewall" "allow_aws_postgresql" {
  name    = "gcp-fw-allow-aws-postgresql"
  network = data.google_compute_network.main.name

  # pglogical 복제: PostgreSQL만 허용
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  # ISMS-P: AWS DB 서브넷만 허용 (전체 VPC 아님)
  source_ranges = var.aws_db_cidrs

  description = "Allow AWS DB subnets to Cloud SQL via VPN (pglogical)"
}

resource "google_compute_firewall" "allow_aws_icmp_dev" {
  name    = "gcp-fw-allow-aws-icmp-dev"
  network = data.google_compute_network.main.name

  # 개발환경 디버깅용 — 운영 전 삭제 필요
  allow {
    protocol = "icmp"
  }

  source_ranges = var.aws_db_cidrs

  description = "DEV ONLY: ICMP for VPN tunnel debugging - remove before production"
}
