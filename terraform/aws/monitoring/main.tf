#monitoring/main.tf
# ─────────────────────────────────────────────────────────
# 보안그룹 — Prometheus/Grafana EC2
# ISMS-P 2.6.1 최소 허용 원칙
# ─────────────────────────────────────────────────────────
resource "aws_security_group" "aws-monitoring-sg" {
  name        = "aws-monitoring-sg"
  description = "Prometheus + Grafana EC2 - app subnet"
  vpc_id      = data.aws_vpc.main.id

  # Grafana 3000 — staff-alb에서만 허용
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [data.aws_security_group.staff_alb.id]
    description     = "Grafana from staff-alb only"
  }

  # Prometheus 9090 — 외부 접근 없음 (로컬만)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = { Name = "aws-monitoring-sg" }
}

# ECS EC2에 node exporter 9100 허용 — monitoring EC2에서만
resource "aws_security_group_rule" "aws-ecs-ec2-allow-node-exporter" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.aws-monitoring-sg.id
  security_group_id        = data.aws_security_group.ecs_ec2.id
  description              = "node exporter scrape from monitoring EC2"
}

# Wazuh에 node exporter 9100 허용 — monitoring EC2에서만
resource "aws_security_group_rule" "aws-wazuh-allow-node-exporter" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.aws-monitoring-sg.id
  security_group_id        = data.aws_security_group.wazuh.id
  description              = "node exporter scrape from monitoring EC2"
}

# ─────────────────────────────────────────────────────────
# Prometheus + Grafana EC2
# ─────────────────────────────────────────────────────────
resource "aws_instance" "aws-monitoring-01" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.app.ids[0]
  vpc_security_group_ids = [aws_security_group.aws-monitoring-sg.id]
  iam_instance_profile   = aws_iam_instance_profile.aws-monitoring-profile.name

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    aws_region             = data.aws_region.current.name
    base_domain            = var.base_domain
    wazuh_manager_ip       = data.terraform_remote_state.wazuh.outputs.wazuh_private_ip
    wazuh_indexer_ip       = data.terraform_remote_state.wazuh_indexer.outputs.indexer_private_ip
  }))

  root_block_device {
    volume_size = 30    # Prometheus TSDB 15일 보존 기준
    volume_type = "gp3"
    encrypted   = true  # ISMS-P 2.7.1 암호화
  }

  tags = { Name = "aws-monitoring-01" }
}

