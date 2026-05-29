# data.tf
# =========================================================
# ECS 모듈 — 외부 리소스 자동 조회
# 팀원이 생성한 리소스를 하드코딩 없이 참조
# =========================================================

# ─────────────────────────────────────────────────────────
# VPC (vpc 모듈: Name = "aws-vpc-01")
# ─────────────────────────────────────────────────────────
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}


# ─────────────────────────────────────────────────────────
# App 서브넷 3개 (vpc 모듈: Name = "aws-app-sub-*")
# ─────────────────────────────────────────────────────────
data "aws_subnets" "app" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["aws-app-sub-*"]
  }
}


# ─────────────────────────────────────────────────────────
# EBS KMS 키 (kms 모듈: alias/aws-kms-ebs-01)
# ─────────────────────────────────────────────────────────
data "aws_kms_key" "ebs" {
  key_id = "alias/aws-kms-ebs-01"
}


# ─────────────────────────────────────────────────────────
# Secrets Manager KMS 키 (kms 모듈: alias/aws-kms-sm-01)
# 태스크 실행 역할이 시크릿 복호화 시 사용
# ─────────────────────────────────────────────────────────
data "aws_kms_key" "secretsmanager" {
  key_id = "alias/aws-kms-sm-01"
}


# ─────────────────────────────────────────────────────────
# Secrets Manager (DATABASE_URL, JWT_SECRET, API_KEY)
# 시크릿 이름은 팀원과 합의한 명명 규칙 사용
# 260528 박경수, 시크릿 네이밍 규칙에 맞추면서 주석화
# ─────────────────────────────────────────────────────────
# data "aws_secretsmanager_secret" "db_url" {
#   name = "hospital/database-url"
# }

# data "aws_secretsmanager_secret" "jwt_secret" {
#   name = "hospital/jwt-secret"
# }

# data "aws_secretsmanager_secret" "api_key" {
#   name = "hospital/api-key"
# }
data "tfe_outputs" "secrets" {
  organization = "k2p"
  workspace    = "TC-aws-secrets"
}

data "aws_caller_identity" "current" {}

# ecs_db_rotator 가 master 계정으로 ALTER USER 실행 시 사용
data "aws_rds_cluster" "main" {
  cluster_identifier = "aws-aurora-01"
}

# ─────────────────────────────────────────────────────────
# ALB Target Group (alb 모듈 apply 후 자동 조회)
# ─────────────────────────────────────────────────────────
data "aws_lb_target_group" "patient" {
  name = "aws-patient-tg"
}

data "aws_lb_target_group" "staff" {
  name = "aws-staff-tg"
}
