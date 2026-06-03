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

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16", "10.10.0.0/16", "172.30.0.0/16"]
    description = "Prometheus remote write — Alloy push (VPC/GCP/onprem)"
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = { Name = "aws-monitoring-sg" }
}


# ─────────────────────────────────────────────────────────
# 단일 EC2 — Prometheus + Grafana
# Private IP 고정 — 하드코딩 금지, 변수로 관리
# reboot/recover 시 IP 유지 → ALB apply 불필요
# ISMS-P 2.9.1 모니터링 서버 가용성 보장
# ─────────────────────────────────────────────────────────
resource "aws_instance" "aws-monitoring-01" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.app.ids[0] 
  vpc_security_group_ids = [aws_security_group.aws-monitoring-sg.id]
  iam_instance_profile   = aws_iam_instance_profile.aws-monitoring-profile.name

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    aws_region       = data.aws_region.current.region
    base_domain      = var.base_domain
    wazuh_manager_ip = data.terraform_remote_state.wazuh.outputs.wazuh_private_ip
    wazuh_indexer_ip = data.terraform_remote_state.wazuh_indexer.outputs.indexer_private_ip
    gcp_proxy_ip     = data.terraform_remote_state.gcp_proxy.outputs.proxy_internal_ip
  }))

  root_block_device {
    volume_size           = 30    # Prometheus TSDB 15일 보존 기준
    volume_type           = "gp3"
    encrypted             = true  # ISMS-P 2.7.1 암호화
    delete_on_termination = true
  }

  tags = { Name = "aws-monitoring-01" }
}

# ─────────────────────────────────────────────────────────
# CloudWatch Alarm — EC2 OS/소프트웨어 장애 시 자동 Reboot
# StatusCheckFailed_Instance: OS 문제, OOM, hang 등
# reboot이라서 IP/EBS 유지 — 데이터 보존
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "aws-monitoring-reboot" {
  alarm_name          = "aws-monitoring-instance-reboot"
  alarm_description   = "monitoring EC2 OS 장애 감지 시 자동 reboot — IP/EBS 유지"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60       # 1분마다 체크
  evaluation_periods  = 3        # 3번 연속 실패 시 알람
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    InstanceId = aws_instance.aws-monitoring-01.id
  }

  # EC2 Reboot 액션
  # 공식문서: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/UsingAlarmActions.html
  alarm_actions = [
    "arn:aws:automate:${data.aws_region.current.region}:ec2:reboot"
  ]

  tags = { Name = "aws-monitoring-instance-reboot" }
}

# ─────────────────────────────────────────────────────────
# CloudWatch Alarm — AWS 하드웨어 장애 시 자동 Recover
# StatusCheckFailed_System: AWS 물리 서버/네트워크 문제
# recover이라서 IP/EBS 유지 — 데이터 보존
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "aws-monitoring-recover" {
  alarm_name          = "aws-monitoring-system-recover"
  alarm_description   = "monitoring EC2 하드웨어 장애 감지 시 자동 recover — IP/EBS 유지"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    InstanceId = aws_instance.aws-monitoring-01.id
  }

  # EC2 Recover 액션
  alarm_actions = [
    "arn:aws:automate:${data.aws_region.current.region}:ec2:recover"
  ]

  tags = { Name = "aws-monitoring-system-recover" }
}

# ─────────────────────────────────────────────────────────
# DLM — 1시간마다 스냅샷 자동 생성
# 실수로 terminate 시 최신 스냅샷으로 복구
# 24개 보관 (24시간치)
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "aws-monitoring-dlm-role" {
  name = "aws-monitoring-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "aws-monitoring-dlm-role" }
}

resource "aws_iam_role_policy_attachment" "aws-monitoring-dlm-policy" {
  role       = aws_iam_role.aws-monitoring-dlm-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "aws-monitoring-snapshot" {
  description        = "monitoring EC2 1시간마다 스냅샷 — 24개 보관"
  execution_role_arn = aws_iam_role.aws-monitoring-dlm-role.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    schedule {
      name = "1시간마다 스냅샷"

      create_rule {
        interval      = 1
        interval_unit = "HOURS"
      }

      retain_rule {
        count = 24  # 24시간치 보관
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
        Purpose         = "monitoring-recovery"
      }
    }

    target_tags = {
      Name = "aws-monitoring-01"
    }
  }

  tags = { Name = "aws-monitoring-dlm-policy" }
}