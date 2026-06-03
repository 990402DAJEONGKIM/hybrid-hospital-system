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


# Wazuh Indexer에 node exporter 9100 허용 — monitoring EC2에서만
resource "aws_security_group_rule" "aws-wazuh-indexer-allow-node-exporter" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.aws-monitoring-sg.id
  security_group_id        = data.aws_security_group.wazuh_indexer.id
  description              = "node exporter scrape from monitoring EC2"
}


# ─────────────────────────────────────────────────────────
# Launch Template — Prometheus/Grafana EC2 설정 정의
# ASG가 EC2 생성 시 이 템플릿을 사용
# user_data 변경 시 version이 자동으로 올라가 ASG Instance Refresh 가능
# ─────────────────────────────────────────────────────────
resource "aws_launch_template" "aws-monitoring-lt" {
  name_prefix   = "aws-monitoring-lt-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.aws-monitoring-sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.aws-monitoring-profile.name
  }

  # user_data — Prometheus/Grafana 설치 스크립트
  # templatefile로 변수 주입 (wazuh IP, gcp IP, region 등)
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    aws_region       = data.aws_region.current.region
    base_domain      = var.base_domain
    wazuh_manager_ip = data.terraform_remote_state.wazuh.outputs.wazuh_private_ip
    wazuh_indexer_ip = data.terraform_remote_state.wazuh_indexer.outputs.indexer_private_ip
    gcp_proxy_ip     = data.terraform_remote_state.gcp_proxy.outputs.proxy_internal_ip
  }))

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 30    # Prometheus TSDB 15일 보존 기준
      volume_type           = "gp3"
      encrypted             = true  # ISMS-P 2.7.1 암호화
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "aws-monitoring-01" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─────────────────────────────────────────────────────────
# Auto Scaling Group — Prometheus/Grafana 단일 EC2 관리
# min=max=desired=1 : 항상 1대 유지 (스케일링 없음)
# EC2 장애 시 ASG가 자동으로 새 EC2 생성 후 ALB TG에 자동 등록
# ALB apply 없이도 자동으로 TG 등록/해제 처리됨
# ISMS-P 2.9.1: 모니터링 서버 가용성 보장
# ─────────────────────────────────────────────────────────
resource "aws_autoscaling_group" "aws-monitoring-asg" {
  name                = "aws-monitoring-asg"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = data.aws_subnets.app.ids

  # staff-alb Grafana TG에 자동 등록
  # TC-aws-ALB의 grafana_tg_arn output 참조
  target_group_arns = [data.terraform_remote_state.alb.outputs.grafana_tg_arn]

  launch_template {
    id      = aws_launch_template.aws-monitoring-lt.id
    version = "$Latest"
  }

  # ELB 헬스체크 — ALB TG 헬스체크 기준으로 EC2 교체
  # 300초 유예 기간: Prometheus/Grafana 설치 완료까지 대기
  health_check_type         = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "aws-monitoring-01"
    propagate_at_launch = true
  }
}