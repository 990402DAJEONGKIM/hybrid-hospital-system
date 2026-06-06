# monitoring/data.tf
# 기존 VPC 참조
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}


data "aws_subnet" "aws-app-sub-2b" {
  tags = { Name = "aws-app-sub-2b" }
}


# staff-alb 보안그룹 참조 (Grafana 인그레스 허용용)
# SG 태그명 aws-staff-alb-sg → aws-hospital-alb-sg 로 수정 — by 김다정, 2026-06-06
data "aws_security_group" "staff_alb" {
  filter {
    name   = "tag:Name"
    values = ["aws-hospital-alb-sg"]
  }
}


data "terraform_remote_state" "kms" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-KMS" }
  }
}


# 단일 EC2 instance ID output — SSM 접속용
output "monitoring_instance_id" {
  description = "모니터링 EC2 인스턴스 ID (SSM 접속용)"
  value       = aws_instance.aws-monitoring-01.id
  sensitive   = true
}


output "monitoring_private_ip" {
  description = "모니터링 EC2 고정 Private IP"
  value       = aws_instance.aws-monitoring-01.private_ip
  sensitive   = true
}

output "grafana_url" {
  description = "Grafana 접속 URL"
  value       = "https://grafana.${var.base_domain}"
  sensitive   = true
}