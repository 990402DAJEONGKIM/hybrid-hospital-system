# ─────────────────────────────────────────
# VPC
# ─────────────────────────────────────────
resource "aws_vpc" "mumbai" {
  provider             = aws.mumbai
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "aws-vpc-02"
  }
}

# ─────────────────────────────────────────
# DB 서브넷
# ─────────────────────────────────────────
resource "aws_subnet" "db_1a" {
  provider          = aws.mumbai
  vpc_id            = aws_vpc.mumbai.id
  cidr_block        = var.db_subnet_cidr_1a
  availability_zone = "ap-south-1a"

  tags = {
    Name = "aws-db-sub-1a"
  }
}

resource "aws_subnet" "db_1b" {
  provider          = aws.mumbai
  vpc_id            = aws_vpc.mumbai.id
  cidr_block        = var.db_subnet_cidr_1b
  availability_zone = "ap-south-1b"

  tags = {
    Name = "aws-db-sub-1b"
  }
}

# ─────────────────────────────────────────
# Route Table
# ─────────────────────────────────────────
resource "aws_route_table" "db" {
  provider = aws.mumbai
  vpc_id   = aws_vpc.mumbai.id

  tags = {
    Name = "aws-db-rt-mumbai"
  }
}

resource "aws_route_table_association" "db_1a" {
  provider       = aws.mumbai
  subnet_id      = aws_subnet.db_1a.id
  route_table_id = aws_route_table.db.id
}

resource "aws_route_table_association" "db_1b" {
  provider       = aws.mumbai
  subnet_id      = aws_subnet.db_1b.id
  route_table_id = aws_route_table.db.id
}

# ─────────────────────────────────────────
# NACL
# ─────────────────────────────────────────
resource "aws_network_acl" "db" {
  provider   = aws.mumbai
  vpc_id     = aws_vpc.mumbai.id
  subnet_ids = [aws_subnet.db_1a.id, aws_subnet.db_1b.id]

  # 인바운드: 하이데라바드 → PostgreSQL 허용
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.hyderabad_vpc_cidr
    from_port  = 5432
    to_port    = 5432
  }

  # 인바운드: 응답 트래픽 허용
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.hyderabad_vpc_cidr
    from_port  = 1024
    to_port    = 65535
  }

  # 인바운드: 나머지 차단
  ingress {
    rule_no    = 32766
    protocol   = "-1"
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  # 아웃바운드: 하이데라바드로만 허용
  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.hyderabad_vpc_cidr
    from_port  = 1024
    to_port    = 65535
  }

  # 아웃바운드: 나머지 차단
  egress {
    rule_no    = 32766
    protocol   = "-1"
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name = "aws-db-nacl-mumbai"
  }
}

# ─────────────────────────────────────────
# Security Group
# ─────────────────────────────────────────
resource "aws_security_group" "rds" {
  provider    = aws.mumbai
  name        = "aws-db-sg-mumbai"
  description = "Mumbai RDS Security Group"
  vpc_id      = aws_vpc.mumbai.id

  ingress {
    description = "PostgreSQL from Hyderabad VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.hyderabad_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "aws-db-sg-mumbai"
  }
}

# ─────────────────────────────────────────
# VPC Peering
# ─────────────────────────────────────────
resource "aws_vpc_peering_connection" "hyderabad_to_mumbai" {
  provider    = aws
  vpc_id      = data.aws_vpc.aws_vpc-01.id
  peer_vpc_id = aws_vpc.mumbai.id
  peer_region = "ap-south-1"
  auto_accept = false

  tags = {
    Name = "aws-vpc-peering-hyderabad-mumbai"
  }
}

resource "aws_vpc_peering_connection_accepter" "mumbai_accept" {
  provider                  = aws.mumbai
  vpc_peering_connection_id = aws_vpc_peering_connection.hyderabad_to_mumbai.id
  auto_accept               = true

  tags = {
    Name = "aws-vpc-peering-hyderabad-mumbai"
  }
}

# Peering 경로 추가 (하이데라바드 → 뭄바이)
resource "aws_route" "hyderabad_to_mumbai" {
  provider                  = aws
  route_table_id            = data.aws_route_table.hyderabad_db.id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.hyderabad_to_mumbai.id
}

# Peering 경로 추가 (뭄바이 → 하이데라바드)
resource "aws_route" "mumbai_to_hyderabad" {
  provider                  = aws.mumbai
  route_table_id            = aws_route_table.db.id
  destination_cidr_block    = var.hyderabad_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.hyderabad_to_mumbai.id
}

# ─────────────────────────────────────────
# Aurora Global Database
# ─────────────────────────────────────────

# Global Database 생성 (하이데라바드 Aurora를 Primary로 등록)
resource "aws_rds_global_cluster" "global" {
  provider                         = aws
  global_cluster_identifier        = "aws-aurora-global"
  source_db_cluster_identifier     = var.hyderabad_rds_arn
  force_destroy                    = false

  
}

# ─────────────────────────────────────────
# 뭄바이 Aurora Secondary 클러스터
# ─────────────────────────────────────────
resource "aws_db_subnet_group" "mumbai" {
  provider   = aws.mumbai
  name       = "aws-db-subnet-group-mumbai"
  subnet_ids = [aws_subnet.db_1a.id, aws_subnet.db_1b.id]

  tags = {
    Name = "aws-db-subnet-group-mumbai"
  }
}

resource "aws_rds_cluster" "mumbai_secondary" {
  provider = aws.mumbai

  cluster_identifier        = "aws-aurora-mumbai"
  global_cluster_identifier = aws_rds_global_cluster.global.id

  engine         = "aurora-postgresql"
  engine_version = var.aurora_engine_version

  db_subnet_group_name   = aws_db_subnet_group.mumbai.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Secondary 클러스터는 마스터 계정 불필요
  skip_final_snapshot = true
  storage_encrypted   = true
  kms_key_id          = var.kms_key_arn

  deletion_protection     = true
  backup_retention_period = 7
  preferred_backup_window = "03:00-04:00"

  # Secondary는 쓰기 불가 (읽기 전용)
  # 하이데라바드 장애 시 수동 또는 자동 승격
  depends_on = [aws_rds_global_cluster.global]

  tags = {
    Name = "aws-aurora-mumbai"
    Role = "secondary"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# 뭄바이 Aurora 인스턴스 (1a - Primary)
resource "aws_rds_cluster_instance" "mumbai_1a" {
  provider = aws.mumbai

  identifier         = "aws-aurora-mumbai-1a"
  cluster_identifier = aws_rds_cluster.mumbai_secondary.id
  instance_class     = "db.t3.medium"
  engine             = aws_rds_cluster.mumbai_secondary.engine
  engine_version     = aws_rds_cluster.mumbai_secondary.engine_version

  availability_zone    = "ap-south-1a"
  db_subnet_group_name = aws_db_subnet_group.mumbai.name

  monitoring_interval = 60
  monitoring_role_arn = var.rds_monitoring_role_arn

  tags = {
    Name = "aws-aurora-mumbai-1a"
    Role = "primary"
  }
}

# 뭄바이 Aurora 인스턴스 (1b - Standby)
resource "aws_rds_cluster_instance" "mumbai_1b" {
  provider = aws.mumbai

  identifier         = "aws-aurora-mumbai-1b"
  cluster_identifier = aws_rds_cluster.mumbai_secondary.id
  instance_class     = "db.t3.medium"
  engine             = aws_rds_cluster.mumbai_secondary.engine
  engine_version     = aws_rds_cluster.mumbai_secondary.engine_version

  availability_zone    = "ap-south-1b"
  db_subnet_group_name = aws_db_subnet_group.mumbai.name

  monitoring_interval = 60
  monitoring_role_arn = var.rds_monitoring_role_arn

  tags = {
    Name = "aws-aurora-mumbai-1b"
    Role = "standby"
  }
}