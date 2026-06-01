# VPC 정보 가져오기
data "aws_vpc" "aws_vpc-01" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}

# 베스천 호스트를 설치할 Public Subnet 정보 가져오기
data "aws_subnet" "aws-pub-sub-2a" {
  filter {
    name   = "tag:Name"
    values = ["aws-pub-sub-2a"]
  }
}

# Aurora 클러스터 정보 가져오기
data "aws_rds_cluster" "aws_aurora_01" {
  cluster_identifier = "aws-aurora-01"
}

# RDS Proxy 유저 시크릿 직접 조회 (tfe_outputs 크로스 워크스페이스 인증 불필요)
data "aws_secretsmanager_secret" "proxy_patient_user" {
  name = "aws-rds-proxy-patient-user-secret"
}

data "aws_secretsmanager_secret" "proxy_staff_user" {
  name = "aws-rds-proxy-staff-user-secret"
}

# Secrets Manager 전용 KMS 키 (Proxy IAM kms:Decrypt 권한에 필요)
data "aws_kms_key" "secretsmanager" {
  key_id = "alias/aws-kms-sm-01"
}