# ─────────────────────────────────────────
# VPC
# ─────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "aws-mumbai-vpc-01"
  }
}

# ─────────────────────────────────────────
# DB 서브넷
# ─────────────────────────────────────────
resource "aws_subnet" "db_1a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnet_cidr_1a
  availability_zone = "ap-south-1a"

  tags = {
    Name = "aws-mumbai-db-sub-1a"
  }
}

resource "aws_subnet" "db_1b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnet_cidr_1b
  availability_zone = "ap-south-1b"

  tags = {
    Name = "aws-mumbai-db-sub-1b"
  }
}

# ─────────────────────────────────────────
# Route Table
# ─────────────────────────────────────────
resource "aws_route_table" "db_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "aws-mumbai-db-rt-01"
  }
}

resource "aws_route_table_association" "db_rta_1a" {
  subnet_id      = aws_subnet.db_1a.id
  route_table_id = aws_route_table.db_rt.id
}

resource "aws_route_table_association" "db_rta_1b" {
  subnet_id      = aws_subnet.db_1b.id
  route_table_id = aws_route_table.db_rt.id
}

# ─────────────────────────────────────────
# NACL
# ─────────────────────────────────────────
resource "aws_network_acl" "db_nacl" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.db_1a.id, aws_subnet.db_1b.id]

  # 인바운드: 하이데라바드 → PostgreSQL 허용
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 5432
    to_port    = 5432
  }

  # 인바운드: 응답 트래픽 허용
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
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
    cidr_block = var.vpc_cidr
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
    Name = "aws-mumbai-db-nacl-01"
  }
}

# ─────────────────────────────────────────
# VPC Peering
# ─────────────────────────────────────────
resource "aws_vpc_peering_connection" "to_hyderabad" {
  vpc_id      = aws_vpc.main.id
  peer_vpc_id = data.terraform_remote_state.hyderabad.outputs.vpc_id
  peer_region = "ap-south-2"
  auto_accept = false

  tags = {
    Name = "aws-mumbai-vpc-peering-01"
  }
}

resource "aws_vpc_peering_connection_accepter" "accept" {
  vpc_peering_connection_id = aws_vpc_peering_connection.to_hyderabad.id
  auto_accept               = true

  tags = {
    Name = "aws-mumbai-vpc-peering-01"
  }
}

# Peering 경로 추가 (뭄바이 → 하이데라바드)
resource "aws_route" "to_hyderabad" {
  route_table_id            = aws_route_table.db_rt.id
  destination_cidr_block    = data.terraform_remote_state.hyderabad.outputs.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_hyderabad.id
}

# ─────────────────────────────────────────
# Aurora Global Database
# ─────────────────────────────────────────
resource "aws_rds_global_cluster" "global" {
  global_cluster_identifier    = "aws-aurora-global"
  source_db_cluster_identifier = data.terraform_remote_state.hyderabad.outputs.rds_arn
  force_destroy                = false
}

# ─────────────────────────────────────────
# Security Group
# ─────────────────────────────────────────
resource "aws_security_group" "rds" {
  name        = "aws-mumbai-rds-sg-01"
  description = "Mumbai RDS security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.hyderabad.outputs.vpc_cidr]
    description = "하이데라바드에서 Aurora 접근"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "aws-mumbai-rds-sg-01"
  }
}

# ─────────────────────────────────────────
# DB 서브넷 그룹
# ─────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "aws-mumbai-db-subnet-group-01"
  subnet_ids = [aws_subnet.db_1a.id, aws_subnet.db_1b.id]

  tags = {
    Name = "aws-mumbai-db-subnet-group-01"
  }
}

# ─────────────────────────────────────────
# KMS
# ─────────────────────────────────────────
resource "aws_kms_key" "rds" {
  description             = "뭄바이 RDS 암호화 KMS Key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "rds" {
  name          = "alias/aws-mumbai-rds-01"
  target_key_id = aws_kms_key.rds.key_id
}

# ─────────────────────────────────────────
# Aurora Secondary 클러스터
# ─────────────────────────────────────────
resource "aws_rds_cluster" "secondary" {
  cluster_identifier        = "aws-mumbai-aurora-01"
  global_cluster_identifier = aws_rds_global_cluster.global.id

  engine         = "aurora-postgresql"
  engine_version = var.aurora_engine_version

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Secondary 클러스터는 마스터 계정 불필요
  skip_final_snapshot = true
  storage_encrypted   = true
  kms_key_id          = aws_kms_key.rds.arn

  deletion_protection     = true
  backup_retention_period = 7
  preferred_backup_window = "03:00-04:00"

  # Secondary는 쓰기 불가 (읽기 전용)
  # 하이데라바드 장애 시 수동 또는 자동 승격
  depends_on = [aws_rds_global_cluster.global]

  tags = {
    Name = "aws-mumbai-aurora-01"
    Role = "secondary"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Aurora 인스턴스 (1a - Writer)
resource "aws_rds_cluster_instance" "writer_1a" {
  identifier         = "aws-mumbai-aurora-01-1a"
  cluster_identifier = aws_rds_cluster.secondary.id
  instance_class     = "db.t3.medium"
  engine             = aws_rds_cluster.secondary.engine
  engine_version     = aws_rds_cluster.secondary.engine_version

  availability_zone    = "ap-south-1a"
  db_subnet_group_name = aws_db_subnet_group.main.name

  monitoring_interval = 0

  tags = {
    Name = "aws-mumbai-aurora-01-1a"
    Role = "writer"
  }
}

# Aurora 인스턴스 (1b - Standby)
resource "aws_rds_cluster_instance" "standby_1b" {
  identifier         = "aws-mumbai-aurora-01-1b"
  cluster_identifier = aws_rds_cluster.secondary.id
  instance_class     = "db.t3.medium"
  engine             = aws_rds_cluster.secondary.engine
  engine_version     = aws_rds_cluster.secondary.engine_version

  availability_zone    = "ap-south-1b"
  db_subnet_group_name = aws_db_subnet_group.main.name

  monitoring_interval = 0

  tags = {
    Name = "aws-mumbai-aurora-01-1b"
    Role = "standby"
  }
}
