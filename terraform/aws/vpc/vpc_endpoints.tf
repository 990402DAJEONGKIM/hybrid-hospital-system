# =========================================================
# VPC Endpoints
#
# Gateway  (무료): S3
#   - 라우팅 테이블 기반, App/DB 서브넷 모두 적용
#
# Interface (유료, $0.013/AZ/시간):
#   - secretsmanager: ECS/Lambda → Secrets Manager (DB 비밀번호)
#                     ISMS-P 2.6.1 — DB 자격증명 공개망 경유 방지
#
# 배치 서브넷:
#   - secretsmanager: App subnet (ECS, ecs-db-rotator Lambda)
#                     DB subnet  (dump Lambda)
# =========================================================

data "aws_region" "current" {}


# ─────────────────────────────────────────────
# 보안 그룹 — Interface Endpoint 공통
# ─────────────────────────────────────────────
resource "aws_security_group" "vpc_endpoints" {
  name        = "aws-vpc-endpoints-sg"
  description = "Interface VPC Endpoints security group"
  vpc_id      = aws_vpc.aws-vpc-01.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.app_cidr_blocks
    description = "HTTPS from App subnets (ECS tasks)"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.db_cidr_blocks
    description = "HTTPS from DB subnets (dump Lambda)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name  = "aws-vpc-endpoints-sg"
    Owner = "st2"
  }
}


# ─────────────────────────────────────────────
# Gateway Endpoint — S3 (무료)
# App + DB 라우팅 테이블 모두 적용
# ─────────────────────────────────────────────
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.aws-vpc-01.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.aws-rt-app-01.id,
    aws_route_table.aws-rt-db-01.id,
  ]

  tags = {
    Name  = "aws-vpce-s3"
    Owner = "st2"
  }
}


# ─────────────────────────────────────────────
# Interface Endpoint — Secrets Manager
# App subnet (ECS, ecs-db-rotator Lambda)
# DB subnet  (dump Lambda)
# ISMS-P 2.6.1 — DB 자격증명 공개망 경유 방지
# ─────────────────────────────────────────────
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id            = aws_vpc.aws-vpc-01.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.secretsmanager"
  vpc_endpoint_type = "Interface"
  subnet_ids = concat(
    [for s in aws_subnet.aws-app-sub : s.id],
    [for s in aws_subnet.aws-db-sub : s.id],
  )
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name  = "aws-vpce-secretsmanager"
    Owner = "st2"
  }
}
