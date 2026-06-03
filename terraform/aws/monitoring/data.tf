# monitoring/data.tf
# 기존 VPC 참조
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpc-01"]
  }
}

# app subnet 참조
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


data "aws_caller_identity" "current" {}
data "aws_region" "current" {}




# staff-alb 보안그룹 참조 (Grafana 인그레스 허용용)
data "aws_security_group" "staff_alb" {
  filter {
    name   = "tag:Name"
    values = ["aws-staff-alb-sg"]
  }
}

# ECS EC2 보안그룹 참조 (node exporter 9100 허용용)
data "aws_security_group" "ecs_ec2" {
  filter {
    name   = "tag:Name"
    values = ["aws-ecs-ec2-sg"]
  }
}

# Wazuh-01 보안그룹 참조
data "aws_security_group" "wazuh" {
  filter {
    name   = "tag:Name"
    values = ["aws-wazuh-sg"]
  }
}

# Wazuh Indexer 보안그룹 참조
data "aws_security_group" "wazuh_indexer" {
  filter {
    name   = "tag:Name"
    values = ["aws-wazuh-indexer-sg"]
  }
}



# Wazuh Manager IP — TC-aws-wazuh output에서 참조
data "terraform_remote_state" "wazuh" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-wazuh" }
  }
}

# Wazuh Indexer IP — TC-aws-wazuh-indexer output에서 참조
data "terraform_remote_state" "wazuh_indexer" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-wazuh-indexer" }
  }
}
data "terraform_remote_state" "kms" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-KMS" }
  }
}

# GCP HAProxy IP — TC-gcp-proxy output에서 참조
data "terraform_remote_state" "gcp_proxy" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-gcp-proxy" }
  }
}





output "monitoring_instance_id" {
  description = "모니터링 EC2 인스턴스 ID (SSM 접속용)"
  value       = aws_instance.aws-monitoring-01.id
  sensitive   = true
}

output "monitoring_private_ip" {
  description = "모니터링 EC2 Private IP"
  value       = aws_instance.aws-monitoring-01.private_ip
  sensitive   = true
}

output "grafana_url" {
  description = "Grafana 접속 URL"
  value       = "https://grafana.${var.base_domain}"
  sensitive   = true
}