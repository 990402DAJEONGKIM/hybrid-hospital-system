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

# DB Route Table 정보 가져오기 (by 김다정 2026.05.18)
# =========================================================================================

data "aws_route_table" "hyderabad_db" {
  filter {
    name   = "tag:Name"
    values = ["aws-rt-db-01"]   # 하이데라바드 DB Route Table 이름
  }
}

# =========================================================================================