# =========================================================
# ALB — Application Load Balancer
#
# ALB 2개:
#   - patient-alb : Public ALB (인터넷 → 환자 포털)
#   - staff-alb   : Internal ALB (VPN → 의료진 포털)
#
# 각 ALB 구성:
#   - HTTP(80)  → HTTPS(443) 리다이렉트
#   - HTTPS(443) → ECS Target Group 포워드
# =========================================================


# ─────────────────────────────────────────────────────────
# 보안그룹 — Public ALB (환자 포털)
# 인터넷에서 80, 443 허용
# ─────────────────────────────────────────────────────────
resource "aws_security_group" "patient_alb" {
  name        = "aws-patient-alb-sg"
  description = "Public ALB security group for patient portal"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP from internet"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "aws-patient-alb-sg" }
}


# ─────────────────────────────────────────────────────────
# 보안그룹 — Internal ALB (의료진 포털)
# VPC 내부(VPN 경유)에서만 80, 443 허용
# ─────────────────────────────────────────────────────────
resource "aws_security_group" "staff_alb" {
  name        = "aws-staff-alb-sg"
  description = "Internal ALB security group for staff portal"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
    description = "HTTP from VPC (VPN)"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
    description = "HTTPS from VPC (VPN)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "aws-staff-alb-sg" }
}


# ─────────────────────────────────────────────────────────
# Target Group — 환자 포털
# ─────────────────────────────────────────────────────────
resource "aws_lb_target_group" "patient" {
  name        = "aws-patient-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "aws-patient-tg" }
}


# ─────────────────────────────────────────────────────────
# Target Group — 의료진 포털
# ─────────────────────────────────────────────────────────
resource "aws_lb_target_group" "staff" {
  name        = "aws-staff-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "aws-staff-tg" }
}


# ─────────────────────────────────────────────────────────
# Public ALB — 환자 포털
# ─────────────────────────────────────────────────────────
resource "aws_lb" "patient" {
  name               = "aws-patient-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.patient_alb.id]
  subnets            = data.aws_subnets.public.ids

  enable_deletion_protection = false

  tags = { Name = "aws-patient-alb" }
}

# HTTP → HTTPS 리다이렉트
resource "aws_lb_listener" "patient_http" {
  load_balancer_arn = aws_lb.patient.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS → Target Group 포워드
resource "aws_lb_listener" "patient_https" {
  load_balancer_arn = aws_lb.patient.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.patient.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.patient.arn
  }
}


# ─────────────────────────────────────────────────────────
# Internal ALB — 의료진 포털
# ─────────────────────────────────────────────────────────
resource "aws_lb" "staff" {
  name               = "aws-staff-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.staff_alb.id]
  subnets            = data.aws_subnets.app.ids

  enable_deletion_protection = false

  tags = { Name = "aws-staff-alb" }
}

# HTTP → HTTPS 리다이렉트
resource "aws_lb_listener" "staff_http" {
  load_balancer_arn = aws_lb.staff.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS → Target Group 포워드
resource "aws_lb_listener" "staff_https" {
  load_balancer_arn = aws_lb.staff.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.staff.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.staff.arn
  }
}


# ─────────────────────────────────────────────────────────
# Route 53 레코드 — ALB DNS 연결
# ─────────────────────────────────────────────────────────
data "aws_route53_zone" "main" {
  name         = var.base_domain
  private_zone = false
}

resource "aws_route53_record" "patient" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "patient.${var.base_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.patient.dns_name
    zone_id                = aws_lb.patient.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "staff" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "staff.${var.base_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.staff.dns_name
    zone_id                = aws_lb.staff.zone_id
    evaluate_target_health = true
  }
}
