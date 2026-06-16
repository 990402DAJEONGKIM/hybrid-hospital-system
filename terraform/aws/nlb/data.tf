data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}

# NLB 배치 서브넷 — app(private) 서브넷, AZ별 고정 IP 지정
# 10.0.11.0/24 (ap-south-2a), 10.0.12.0/24 (ap-south-2b), 10.0.13.0/24 (ap-south-2c)
# VPN 라우팅(10.0.0.0/16)으로 온프레미스에서 직접 도달 가능
data "aws_subnet" "app_2a" {
  filter {
    name   = "tag:Name"
    values = ["aws-app-sub-2a"]
  }
}

data "aws_subnet" "app_2b" {
  filter {
    name   = "tag:Name"
    values = ["aws-app-sub-2b"]
  }
}

data "aws_subnet" "app_2c" {
  filter {
    name   = "tag:Name"
    values = ["aws-app-sub-2c"]
  }
}

# External ALB ARN — AWS API로 직접 조회 (cross-workspace state 접근 불필요)
data "aws_lb" "external" {
  name = "aws-hospital-alb"
}
