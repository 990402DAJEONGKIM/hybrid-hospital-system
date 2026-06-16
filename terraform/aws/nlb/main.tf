# =========================================================
# Internal NLB — 온프레미스 VPN 전용 접근 경로
#
# 트래픽 흐름:
#   클라이언트(hosts: 10.0.11.10) → VPN → Internal NLB → External ALB → ECS
#
# 환자(인터넷) 경로는 기존 그대로 유지:
#   Route53 → External ALB → ECS
# =========================================================


# ─────────────────────────────────────────────────────────
# Target Group — External ALB를 타겟으로 지정
#
# target_type = "alb": NLB가 ALB 자체를 타겟으로 사용
# → ALB가 TLS 종료 + SNI 기반 인증서 선택 + 호스트 라우팅 처리
# → mzclinic.cloud → hospital-tg → ECS 라우팅 기존 그대로 동작
#
# 헬스체크: ALB가 살아있는지 확인 (호스트 헤더 없어 403 반환 → 정상)
# ─────────────────────────────────────────────────────────
resource "aws_lb_target_group" "alb_target" {
  name        = "aws-internal-nlb-tg-01"
  port        = 443
  protocol    = "TCP"
  target_type = "alb"
  vpc_id      = data.aws_vpc.main.id

  health_check {
    protocol            = "HTTPS"
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    matcher             = "200-403"
  }

  tags = { Name = "aws-internal-nlb-tg-01" }
}

resource "aws_lb_target_group_attachment" "alb" {
  target_group_arn = aws_lb_target_group.alb_target.arn
  target_id        = data.aws_lb.external.arn
  port             = 443
}


# ─────────────────────────────────────────────────────────
# Internal NLB
#
# - app(private) 서브넷 배치: 인터넷에서 직접 접근 불가
# - 고정 사설 IP 지정: 클라이언트 hosts 파일에 등록할 주소
#   ap-south-2a → 10.0.11.10
#   ap-south-2b → 10.0.12.10
#   ap-south-2c → 10.0.13.10 (ECS 오토스케일링 대상 AZ 추가)
# - VPN 라우팅(10.0.0.0/16 via 172.30.1.254)으로 온프레미스에서 도달
# - NLB는 보안그룹 없음 (L4 장비)
#   ALB SG가 이미 0.0.0.0/0:443 허용 중이므로 별도 변경 불필요
# ─────────────────────────────────────────────────────────
resource "aws_lb" "internal" {
  name               = "aws-internal-nlb-01"
  internal           = true
  load_balancer_type = "network"

  subnet_mapping {
    subnet_id            = data.aws_subnet.app_2a.id
    private_ipv4_address = var.nlb_ip_2a
  }

  subnet_mapping {
    subnet_id            = data.aws_subnet.app_2b.id
    private_ipv4_address = var.nlb_ip_2b
  }

  subnet_mapping {
    subnet_id            = data.aws_subnet.app_2c.id
    private_ipv4_address = var.nlb_ip_2c
  }

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = { Name = "aws-internal-nlb-01" }
}


# ─────────────────────────────────────────────────────────
# NLB 리스너 — TCP:443 패스스루
#
# TCP 프로토콜 사용: TLS를 NLB에서 종료하지 않고 ALB로 그대로 전달
# → ALB가 클라이언트의 TLS ClientHello(SNI=mzclinic.cloud)를 수신
# → ALB가 ACM 인증서로 TLS 종료 → 호스트 기반 라우팅 처리
# ─────────────────────────────────────────────────────────
resource "aws_lb_listener" "tcp_443" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_target.arn
  }
}
