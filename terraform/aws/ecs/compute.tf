#compute.tf

# =========================================================
# ECS EC2 컴퓨트: 보안그룹 + Launch Template + ASG
# 아키텍처: 상시 2대, 트래픽 급증 시 최대 3대 (Auto Scaling + Warm Pool)
# =========================================================


# ─────────────────────────────────────────────────────────
# 보안 그룹 — ECS EC2 인스턴스
# ALB → EC2(port 80) 허용, 아웃바운드 전체 허용
# ─────────────────────────────────────────────────────────
resource "aws_security_group" "ecs_ec2" {
  name        = "aws-ecs-ec2-sg"
  description = "ECS EC2 instance security group"
  vpc_id      = var.vpc_id

  # ALB → NGINX (port 80) — VPC 내부에서만 허용
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "ALB to NGINX"
  }

  # 아웃바운드: ECR Pull, CloudWatch, Secrets Manager, RDS Proxy
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "aws-ecs-ec2-sg" }
}


# ─────────────────────────────────────────────────────────
# Launch Template
# ─────────────────────────────────────────────────────────
resource "aws_launch_template" "ecs" {
  name_prefix   = "aws-ecs-lt-"
  image_id      = var.ec2_ami_id
  instance_type = var.ec2_instance_type

  key_name = var.ec2_key_name != "" ? var.ec2_key_name : null

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance.name
  }

  vpc_security_group_ids = [aws_security_group.ecs_ec2.id]

  # EBS 루트 볼륨 암호화 (ISMS-P 2.7.1)
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = data.aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  # EC2 메타데이터 서비스 v2 강제 (SSRF 방지, ISMS-P 2.10.1)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # User Data: ECS 클러스터 등록 + Wazuh 에이전트 설치
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    cluster_name    = aws_ecs_cluster.main.name
    wazuh_server_ip = var.wazuh_server_ip
    aws_region      = var.aws_region
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "aws-ecs-ec2" }
  }

  lifecycle {
    create_before_destroy = true
  }
}


# ─────────────────────────────────────────────────────────
# Auto Scaling Group
# 상시 2대 운영, 트래픽 급증 시 1대 추가 → 최대 3대
# 2대 상시 유지: 롤링 배포 시 다운타임 없음 (1대가 트래픽 처리)
# ─────────────────────────────────────────────────────────
resource "aws_autoscaling_group" "ecs" {
  name                = "aws-ecs-asg-01"
  vpc_zone_identifier = data.aws_subnets.app.ids

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_size

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  # ECS Capacity Provider 연동 시 필수
  protect_from_scale_in = true

  # 헬스체크: EC2 상태 기반 (ECS 태스크는 ECS가 별도 관리)
  health_check_type         = "EC2"
  health_check_grace_period = 120

  tag {
    key                 = "Name"
    value               = "aws-ecs-ec2"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  # Warm Pool — 콜드 스타트 해결
  # Stopped 인스턴스를 미리 대기시켜 스케일 아웃 시 60~90초로 단축
  # 비용: EBS $2.4/월만 과금 (인스턴스 시간 요금 없음)
  warm_pool {
    pool_state                  = "Stopped"
    min_size                    = 1
    max_group_prepared_capacity = 2

    instance_reuse_policy {
      reuse_on_scale_in = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}


