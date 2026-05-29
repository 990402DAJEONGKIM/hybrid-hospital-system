# =========================================================
# ALB — Application Load Balancer
#
# ALB 2개:
#   - patient-alb : Public ALB (인터넷 → 환자 포털)
#   - staff-alb   : 통합 ALB (의료진 포털 + Wazuh 대시보드)
#                   host-based 라우팅으로 두 서비스 분기
#                   WAF IP 화이트리스트로 병원 내부 IP만 허용
#
# staff-alb 라우팅:
#   - staff.mzclinic.cloud  → ECS staff TG  (HTTPS:443, WAF IP 제한)
#   - wazuh.mzclinic.cloud  → Wazuh EC2 TG  (HTTPS:443, private subnet)
#   - 그 외 host            → 403 고정 응답
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
# 보안그룹 — Public ALB (의료진 포털)
# WAF IP 화이트리스트로 허용 IP 제한 — ALB SG는 전체 허용
# ─────────────────────────────────────────────────────────
resource "aws_security_group" "staff_alb" {
  name        = "aws-staff-alb-sg"
  description = "Public ALB security group for staff portal (WAF IP whitelist applied)"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP from internet (WAF handles IP restriction)"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet (WAF handles IP restriction)"
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
  target_type = "ip"

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
  target_type = "ip"

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
# Target Group — Wazuh 대시보드 (private subnet EC2, HTTPS)
# Wazuh 대시보드는 port 443 HTTPS (자체 서명 인증서)
# ALB → 타겟 HTTPS 연결 시 인증서 검증 없음 (기본 동작)
# ─────────────────────────────────────────────────────────
resource "aws_lb_target_group" "wazuh" {
  name        = "aws-wazuh-tg"
  port        = 443
  protocol    = "HTTPS"
  vpc_id      = data.aws_vpc.main.id
  target_type = "instance"

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  health_check {
    path                = "/"
    protocol              = "HTTPS"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
    matcher             = "200-302"
  }

  tags = { Name = "aws-wazuh-tg" }
}

resource "aws_lb_target_group_attachment" "wazuh" {
  target_group_arn = aws_lb_target_group.wazuh.arn
  target_id        = data.aws_instance.wazuh.id
  port             = 443
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
  # access_logs {
  #   bucket  = "aws-k2p-storage-01"
  #   prefix  = "alb/patient"
  #   enabled = true
  # }
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
# 통합 ALB — 의료진 포털 + Wazuh 대시보드
# host-based 라우팅으로 두 서비스 분기
# ─────────────────────────────────────────────────────────
resource "aws_lb" "staff" {
  name               = "aws-staff-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.staff_alb.id]
  subnets            = data.aws_subnets.public.ids
  # access_logs {
  #   bucket  = "aws-k2p-storage-01"
  #   prefix  = "alb/staff"
  #   enabled = true
  # }
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

# HTTPS 리스너 — 기본 인증서: staff.mzclinic.cloud
# 매칭되지 않는 host → 403 고정 응답
resource "aws_lb_listener" "staff_https" {
  load_balancer_arn = aws_lb.staff.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.staff.arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "403 Forbidden"
      status_code  = "403"
    }
  }
}

# 추가 인증서 — wazuh.mzclinic.cloud (SNI)
resource "aws_lb_listener_certificate" "wazuh" {
  listener_arn    = aws_lb_listener.staff_https.arn
  certificate_arn = data.aws_acm_certificate.wazuh.arn
}

# 라우팅 규칙 — staff.mzclinic.cloud → ECS staff TG
resource "aws_lb_listener_rule" "staff" {
  listener_arn = aws_lb_listener.staff_https.arn
  priority     = 10

  condition {
    host_header {
      values = ["staff.${var.base_domain}"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.staff.arn
  }
}

# 라우팅 규칙 — wazuh.mzclinic.cloud → Wazuh EC2 TG
resource "aws_lb_listener_rule" "wazuh" {
  listener_arn = aws_lb_listener.staff_https.arn
  priority     = 20

  condition {
    host_header {
      values = ["wazuh.${var.base_domain}"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.wazuh.arn
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

resource "aws_route53_record" "wazuh" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "wazuh.${var.base_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.staff.dns_name
    zone_id                = aws_lb.staff.zone_id
    evaluate_target_health = true
  }
}
