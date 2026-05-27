
# ─────────────────────────────────────────────
# 데이터 소스 — 기존 리소스 참조
# ─────────────────────────────────────────────
data "aws_vpc" "main" {
  id = var.vpc_id
}


# ─────────────────────────────────────────────
# 보안 그룹 1: Proxy용 (aws-sg-proxy-01)
# ─────────────────────────────────────────────
resource "aws_security_group" "proxy" {
  name        = "aws-proxy-sg"
  description = "rds proxy sg"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.app_subnet_cidrs
    content {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
      description = "App subnet ${ingress.value}"
    }
  }

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr]
    description = "On-premises VPN"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "aws-proxy-sg" })
}


# ─────────────────────────────────────────────
# 보안 그룹 2: Aurora 클러스터용 (aws-sg-rds-01)
# ─────────────────────────────────────────────
resource "aws_security_group" "rds" {
  name        = "aws-rds-sg"
  description = "rds sg"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.proxy.id]
    description     = "RDS Proxy to Aurora"
  }

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr]
    description = "On-premises direct access"
  }

  # bastion host -> Aurora
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.aws_bastion_sg.id]
    description     = "Bastion Host to Aurora"
  }

  # GCP HAProxy VM (gcp-vpc subnet) -> Aurora (pglogical)
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.gcp_subnet_cidr]
    description = "GCP HAProxy to Aurora (pglogical replication)"
  }

  # GCP Cloud SQL PSA -> Aurora (pglogical fallback)
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.gcp_psa_cidr]
    description = "GCP Cloud SQL PSA to Aurora (pglogical)"
  }

  # ecs ec2 -> Aurora  (by 김다정 2026.05.24)
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [data.aws_security_group.ecs_ec2.id]
    description     = "ECS tasks to Aurora"
  }

  # GCP Cloud Functions VPC Connector -> Aurora (rotation) (260526 박경수 추가)
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.10.2.0/28"]
    description = "GCP Cloud Functions VPC Connector (rotation)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "aws-rds-sg" })
}


# ─────────────────────────────────────────────
# DB 서브넷 그룹
# ─────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name        = "aws-db-subnet-group-01"
  description = "Hospital DB subnet group - DB tier 10.0.21~23.0/24"
  subnet_ids  = var.db_subnet_ids

  tags = merge(local.common_tags, { Name = "aws-db-subnet-group-01" })
}


# ─────────────────────────────────────────────
# Aurora 클러스터 파라미터 그룹 (pglogical)
# ─────────────────────────────────────────────
resource "aws_rds_cluster_parameter_group" "pglogical" {
  name        = "aws-aurora-01-pglogical"
  family      = "aurora-postgresql17"
  description = "Aurora PostgreSQL 17 pglogical logical replication"

  # enable logical replication (reboot required)
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
  
  # preload pglogical extension (reboot required)
  parameter {
    name         = "shared_preload_libraries"
    value        = "pglogical,pgaudit"  # 2026-05-20 김강환 pgaudit 추가(누가 언제 어떤 데이터를 조회/수정/삭제했는지 기록)
    apply_method = "pending-reboot"
  }

  # replication slots (subscriber count + buffer)
  parameter {
    name         = "max_replication_slots"
    value        = "10"
    apply_method = "pending-reboot"
  }

  # wal senders
  parameter {
    name         = "max_wal_senders"
    value        = "10"
    apply_method = "pending-reboot"
  }

  # required for pglogical conflict resolution
  parameter {
    name         = "track_commit_timestamp"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # disable wal sender timeout (long-distance replication)
  parameter {
    name         = "wal_sender_timeout"
    value        = "0"
    apply_method = "immediate"
  }
  # 2026-05-20 김강환 pgaudit 추가(누가 언제 어떤 데이터를 조회/수정/삭제했는지 기록)
  parameter {
    name         = "pgaudit.log"
    value        = "write,ddl,role"
    apply_method = "pending-reboot"
  }
  # 2026-05-20 김강환 pgaudit 추가(누가 언제 어떤 데이터를 조회/수정/삭제했는지 기록)
  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = merge(local.common_tags, { Name = "aws-aurora-01-pglogical" })
}


# ─────────────────────────────────────────────
# Aurora 클러스터
# ─────────────────────────────────────────────
resource "aws_rds_cluster" "main" {
  cluster_identifier          = "aws-aurora-01"
  engine                      = "aurora-postgresql"
  engine_version              = var.db_engine_version
  master_username             = var.db_master_username
  manage_master_user_password = true

  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.rds.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.pglogical.name  # pglogical

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "07:33-08:03"
  preferred_maintenance_window = "tue:13:25-tue:13:55"

  storage_encrypted = false  # 기존 RDS랑 맞게 false로 변경
  kms_key_id        = null   # kms도 null로

  #storage_encrypted = true
  #kms_key_id        = var.rds_kms_key_arn

  # 삭제 방지 설정
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "aws-aurora-01-final-snapshot"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = merge(local.common_tags, { Name = "aws-aurora-01" })
}


# ─────────────────────────────────────────────
# Writer 인스턴스
# ─────────────────────────────────────────────
resource "aws_rds_cluster_instance" "writer" {
  identifier              = "aws-aurora-01-instance-1-ap-south-2a"
  cluster_identifier      = aws_rds_cluster.main.id
  instance_class          = var.db_instance_class
  engine                  = aws_rds_cluster.main.engine
  engine_version          = aws_rds_cluster.main.engine_version

  db_subnet_group_name    = aws_db_subnet_group.main.name

  availability_zone       = "${var.aws_region}a"
  promotion_tier          = 0

  monitoring_interval     = 0

  # 인스턴스 삭제 방지
  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "aws-aurora-01-writer", Role = "writer" })
}


# ─────────────────────────────────────────────
# IAM Role — Enhanced Monitoring
# ─────────────────────────────────────────────
resource "aws_iam_role" "enhanced_monitoring" {
  name = "aws-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "aws-rds-monitoring-role" })
}

resource "aws_iam_role_policy_attachment" "enhanced_monitoring" {
  role       = aws_iam_role.enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}


# ─────────────────────────────────────────────
# IAM Role — RDS Proxy -> Secrets Manager
# ─────────────────────────────────────────────
resource "aws_iam_role" "rds_proxy" {
  name = "aws-rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "aws-rds-proxy-role" })
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "rds-proxy-secrets-access"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = [
        "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:aws-secret-rds-hospital-user*",
        "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:aws-secret-rds-api-user*"
      ]
    }]
  })
}


# ─────────────────────────────────────────────
# RDS Proxy (toggle.sh로 별도 관리 — 주석 해제 후 import)
# ─────────────────────────────────────────────
# resource "aws_db_proxy" "main" { ... }


# bastion host 용 (by 김다정 2026.05.13)
# =========================================================================================
resource "aws_iam_role" "aws_bastion_role" {
  name = "aws-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws_ssm_attachment" {
  role       = aws_iam_role.aws_bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "aws_bastion_profile" {
  name = "aws-bastion-profile"
  role = aws_iam_role.aws_bastion_role.name
}

resource "aws_security_group" "aws_bastion_sg" {
  name   = "aws-bastion-sg"
  vpc_id = data.aws_vpc.aws_vpc-01.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "aws_bastion_01" {
  ami                  = "ami-0603dd3984985653f"
  instance_type        = "t3.micro"
  iam_instance_profile = aws_iam_instance_profile.aws_bastion_profile.name

  subnet_id              = data.aws_subnet.aws-pub-sub-2a.id
  vpc_security_group_ids = [aws_security_group.aws_bastion_sg.id]

  tags = {
    Name = "aws-bastion-01"
  }
}
# =========================================================================================


# ecs 용 (by 김다정 2026.05.24)
# =========================================================================================
data "aws_security_group" "ecs_ec2" {
  name = "aws-ecs-ec2-sg"
}
# =========================================================================================