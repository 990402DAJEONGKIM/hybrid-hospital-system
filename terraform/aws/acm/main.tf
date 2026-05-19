# =========================================================
# ACM — SSL/TLS 인증서
#
# 인증서 2개:
#   - patient : 환자 포털 (Public ALB)
#   - staff   : 의료진 포털 (Internal ALB, VPN 전용)
#
# 검증 방식: DNS 검증 (Route 53 레코드 자동 생성)
#   - Email 검증 대비 갱신 자동화 가능 (ISMS-P 2.7.1)
#   - 인증서 만료 60일 전 자동 갱신 (ACM 관리형)
# =========================================================


# ─────────────────────────────────────────────────────────
# 1. 환자 포털 인증서 (Public ALB용)
# ─────────────────────────────────────────────────────────
resource "aws_acm_certificate" "patient" {
  domain_name       = var.patient_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "acm-patient-portal" }
}

# DNS 검증 레코드 — Route 53에 자동 생성
resource "aws_route53_record" "patient_validation" {
  for_each = {
    for dvo in aws_acm_certificate.patient.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# 검증 완료 대기 (ALB 리스너 생성 전 완료 보장)
resource "aws_acm_certificate_validation" "patient" {
  certificate_arn         = aws_acm_certificate.patient.arn
  validation_record_fqdns = [for r in aws_route53_record.patient_validation : r.fqdn]
}


# ─────────────────────────────────────────────────────────
# 2. 의료진 포털 인증서 (Internal ALB용)
# ─────────────────────────────────────────────────────────
resource "aws_acm_certificate" "staff" {
  domain_name       = var.staff_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "acm-staff-portal" }
}

resource "aws_route53_record" "staff_validation" {
  for_each = {
    for dvo in aws_acm_certificate.staff.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "staff" {
  certificate_arn         = aws_acm_certificate.staff.arn
  validation_record_fqdns = [for r in aws_route53_record.staff_validation : r.fqdn]
}
