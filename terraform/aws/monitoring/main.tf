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
    description = "Prometheus remote write from Alloy push (VPC/GCP/onprem)"
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
  subnet_id              = data.aws_subnet.aws-app-sub-2b.id
  private_ip             = var.monitoring_private_ip
  vpc_security_group_ids = [aws_security_group.aws-monitoring-sg.id]
  iam_instance_profile   = aws_iam_instance_profile.aws-monitoring-profile.name

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    aws_region        = data.aws_region.current.region
    base_domain       = var.base_domain
    # #260609 박경수 — Keycloak 설치용 변수 추가
    aurora_endpoint   = var.aurora_endpoint
    monitoring_domain = var.monitoring_domain
    wazuh_private_ip  = var.wazuh_private_ip
    # #260609 박경수 end
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
  alarm_description   = "monitoring EC2 OS failure - auto reboot, IP/EBS preserved"
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
  alarm_description   = "monitoring EC2 hardware failure - auto recover, IP/EBS preserved"
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
  description        = "monitoring EC2 snapshot every 1 hour - 24 count"
  execution_role_arn = aws_iam_role.aws-monitoring-dlm-role.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    schedule {
      name = "snapshot every 1 hour"

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
# ─────────────────────────────────────────────────────────
# #260609 박경수 — Keycloak + 통합 포털
# ─────────────────────────────────────────────────────────

# 기존 aws-hospital-alb data source
data "aws_lb" "hospital" {
  name = "aws-hospital-alb"
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.hospital.arn
  port              = 443
}

# nginx 80 포트 — ALB SG에서만 허용 (ISMS-P 2.6.1)
resource "aws_security_group_rule" "keycloak_from_alb" {
  description              = "nginx from ALB only"
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = tolist(data.aws_lb.hospital.security_groups)[0]
  security_group_id        = aws_security_group.aws-monitoring-sg.id
}

# Aurora (5432) — monitoring EC2 → Keycloak DB 접근
resource "aws_security_group_rule" "aurora_from_monitoring" {
  description              = "Aurora access from monitoring EC2 for Keycloak DB"
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.aws-monitoring-sg.id
  security_group_id        = var.aurora_sg_id
}

# Keycloak ALB 타겟그룹
resource "aws_lb_target_group" "keycloak" {
  name        = "aws-keycloak-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    port                = "80"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200,301,302"
  }

  tags = { Name = "aws-keycloak-tg" }
}

resource "aws_lb_target_group_attachment" "keycloak" {
  target_group_arn = aws_lb_target_group.keycloak.arn
  target_id        = aws_instance.aws-monitoring-01.id
  port             = 80
}

# ALB 리스너 규칙 — monitoring.mzclinic.cloud → Keycloak + 통합 포털
# priority 10 (기존 5, 20, 30보다 앞)
resource "aws_lb_listener_rule" "monitoring" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = 10

  condition {
    host_header {
      values = [var.monitoring_domain]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}

# Cloudflare DNS — monitoring.mzclinic.cloud → hospital ALB (CNAME)
resource "cloudflare_record" "monitoring" {
  zone_id = var.cloudflare_zone_id
  name    = "monitoring"
  content = data.aws_lb.hospital.dns_name
  type    = "CNAME"
  ttl     = 1
  proxied = true
}
# #260609 박경수 end

# #260609 박경수 — Keycloak 설치 스크립트 S3 업로드
# user_data 16KB 제한으로 S3 분리
resource "aws_s3_object" "keycloak_setup" {
  bucket  = data.aws_s3_bucket.scripts.id
  key     = "monitoring/keycloak_setup.sh"
  content = file("${path.module}/keycloak_setup.sh")
}
# #260609 박경수 end
