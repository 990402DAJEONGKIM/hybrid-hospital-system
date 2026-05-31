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

# TC-aws-secrets 워크스페이스 outputs (Proxy auth 시크릿 ARN 참조)
data "tfe_outputs" "secrets" {
  organization = "k2p"
  workspace    = "TC-aws-secrets"
}