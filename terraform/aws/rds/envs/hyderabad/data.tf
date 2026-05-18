# VPC 정보 가져오기
data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}

# 베스천 호스트를 설치할 Public Subnet 정보 가져오기
data "aws_subnet" "pub_sub_2a" {
  filter {
    name   = "tag:Name"
    values = ["aws-pub-sub-2a"]
  }
}

# Aurora 클러스터 정보 가져오기
data "aws_rds_cluster" "aurora_01" {
  cluster_identifier = "aws-aurora-01"
}

# DB Route Table 정보 가져오기 (by 김다정 2026.05.18)
# =========================================================================================

data "aws_route_table" "rt_db_01" {
  filter {
    name   = "tag:Name"
    values = ["aws-rt-db-01"]   # 하이데라바드 DB Route Table 이름
  }
}
# =========================================================================================