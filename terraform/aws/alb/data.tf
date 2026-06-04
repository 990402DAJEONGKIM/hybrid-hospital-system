# =========================================================
# 외부 리소스 자동 조회
# =========================================================

data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}

# Public ALB (환자 포털) — 퍼블릭 서브넷 3개
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["aws-pub-sub-*"]
  }
}

# Internal ALB (의료진 포털) — 앱 서브넷 3개
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

# ACM 인증서 (patient.mzclinic.cloud)
data "aws_acm_certificate" "patient" {
  domain      = "patient.${var.base_domain}"
  statuses    = ["ISSUED"]
  most_recent = true
}

# ACM 인증서 (staff.mzclinic.cloud)
data "aws_acm_certificate" "staff" {
  domain      = "staff.${var.base_domain}"
  statuses    = ["ISSUED"]
  most_recent = true
}

# ACM 인증서 (wazuh.mzclinic.cloud) — 통합 ALB 추가 인증서
data "aws_acm_certificate" "wazuh" {
  domain      = "wazuh.${var.base_domain}"
  statuses    = ["ISSUED"]
  most_recent = true
}

# Grafana ACM 인증서 — staff-alb SNI 추가용
# TC-aws-ACM에서 grafana 인증서 발급 후 사용 가능
data "aws_acm_certificate" "grafana" {
  domain      = "grafana.${var.base_domain}"
  statuses    = ["ISSUED"]
  most_recent = true
}

# ACM 인증서 (admin.mzclinic.cloud) 삭제 — admin.mzclinic.cloud 제거, staff로 통합
# data "aws_acm_certificate" "admin" {
#   domain      = "admin.${var.base_domain}"
#   statuses    = ["ISSUED"]
#   most_recent = true
# }




# ECS EC2 보안그룹 (ALB → ECS 트래픽 허용 규칙 추가용)
data "aws_security_group" "ecs_ec2" {
  filter {
    name   = "tag:Name"
    values = ["aws-ecs-ec2-sg"]
  }
}

# Wazuh EC2 (private subnet, 포트 443 — 대시보드)
data "aws_instance" "wazuh" {
  filter {
    name   = "tag:Name"
    values = ["aws-wazuh-01"]
  }
  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}



data "terraform_remote_state" "s3" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-S3" }
  }
}




# monitoring EC2 Private IP 참조
# TC-aws-monitoring output에서 가져옴
data "terraform_remote_state" "monitoring" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-monitoring" }
  }
}