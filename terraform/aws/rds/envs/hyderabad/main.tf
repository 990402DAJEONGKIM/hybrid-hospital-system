
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
# Aurora 클러스터
# ─────────────────────────────────────────────

# =========================================================================================
# Aurora 클러스터용 KMS  (by 김다정 2026.05.18)
resource "aws_kms_key" "kms" {
  description             = "하이데라바드 RDS 암호화 KMS Key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "rds_alias" {
  name          = "alias/hyderabad-rds"
  target_key_id = aws_kms_key.kms.key_id
}
# ==================================================================================


resource "aws_rds_cluster" "main" {
  cluster_identifier              = "aws-aurora-01"
  engine                          = "aurora-postgresql"
  engine_version                  = var.db_engine_version
  master_username                 = var.db_master_username
  manage_master_user_password     = true

  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.rds.id]

  backup_retention_period         = var.backup_retention_days
  preferred_backup_window         = "07:33-08:03"
  preferred_maintenance_window    = "tue:13:25-tue:13:55"

  storage_encrypted               = true   # KMS 암호화 활성화
  deletion_protection             = false
  kms_key_id        = aws_kms_key.kms.arn  # KMS 키 참조 (by 김다정 2026.05.18)


  enabled_cloudwatch_logs_exports = ["postgresql"]

  skip_final_snapshot             = true

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
# IAM Role — RDS Proxy → Secrets Manager
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
# resource "aws_db_proxy" "main" {
#   name                   = "aws-rds-proxy-01"
#   debug_logging          = false
#   engine_family          = "POSTGRESQL"
#   idle_client_timeout    = 1800
#   require_tls            = true
#   role_arn               = aws_iam_role.rds_proxy.arn
#   vpc_security_group_ids = [aws_security_group.proxy.id]
#   vpc_subnet_ids         = var.db_subnet_ids
#
#   auth {
#     auth_scheme = "SECRETS"
#     iam_auth    = "DISABLED"
#     secret_arn  = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:aws-secret-rds-hospital-user"
#   }
#
#   auth {
#     auth_scheme = "SECRETS"
#     iam_auth    = "DISABLED"
#     secret_arn  = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:aws-secret-rds-api-user"
#   }
#
#   tags = merge(local.common_tags, { Name = "aws-rds-proxy-01" })
# }
#
# resource "aws_db_proxy_default_target_group" "main" {
#   db_proxy_name = aws_db_proxy.main.name
#
#   connection_pool_config {
#     connection_borrow_timeout    = 120
#     max_connections_percent      = 100
#     max_idle_connections_percent = 50
#   }
# }
#
# resource "aws_db_proxy_target" "main" {
#   db_cluster_identifier = aws_rds_cluster.main.id
#   db_proxy_name         = aws_db_proxy.main.name
#   target_group_name     = aws_db_proxy_default_target_group.main.name
# }




# bastion host 용 (by 김다정 2026.05.13)
# =========================================================================================
# ssm 연결을 위한 IAM Role (EC2가 SSM 서비스를 쓸 수 있게 허용)
resource "aws_iam_role" "bastion_role" {
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

# SSM 관리형 정책 연결
resource "aws_iam_role_policy_attachment" "ssm_attachment" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 3. EC2 인스턴스 프로파일
resource "aws_iam_instance_profile" "bastion_profile" {
  name = "bastion-profile"
  role = aws_iam_role.bastion_role.name
}

# 베스천 전용 보안 그룹
resource "aws_security_group" "bastion_sg" {
  name   = "aws-bastion-sg"
  vpc_id = data.aws_vpc.main.id

  # 아웃바운드는 RDS(5432) 접근을 위해 전체 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 5. 베스천 EC2 인스턴스 생성
resource "aws_instance" "bastion_01" {
  count                = var.bastion_count # 이 부분이 bash 스크립트와 연동됨, 0이면 생성 안 함, 1이면 생성
  ami                  = "ami-0603dd3984985653f" 
  instance_type        = "t3.micro"
  iam_instance_profile = aws_iam_instance_profile.bastion_profile.name
  
  subnet_id              = data.aws_subnet.pub-sub-2a.id
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]

  tags = {
    Name = "aws-bastion-01"
  }
}
# =========================================================================================

