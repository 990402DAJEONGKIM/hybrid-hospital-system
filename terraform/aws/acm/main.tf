# =========================================================
# ACM — SSL/TLS 인증서
#
# 인증서 2개:
#   - patient : 환자 포털 (Public ALB)
#   - staff   : 의료진 포털 (Internal ALB)
#
# 검증 방식: DNS 검증 (Route 53 레코드 자동 생성)
#   - Email 검증 대비 갱신 자동화 가능 (ISMS-P 2.7.1)
#   - 인증서 만료 60일 전 자동 갱신 (ACM 관리형)
# =========================================================


# ─────────────────────────────────────────────────────────
# Route 53 Hosted Zone 자동 조회 (하드코딩 불필요)
# ─────────────────────────────────────────────────────────
data "aws_route53_zone" "main" {
  name         = var.base_domain
  private_zone = false
}

locals {
  patient_domain = "${var.patient_subdomain}.${var.base_domain}"
  staff_domain   = "${var.staff_subdomain}.${var.base_domain}"
  wazuh_domain   = "${var.wazuh_subdomain}.${var.base_domain}"
}


# ─────────────────────────────────────────────────────────
# 1. 환자 포털 인증서 (Public ALB용)
# ─────────────────────────────────────────────────────────
resource "aws_acm_certificate" "patient" {
  domain_name       = local.patient_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "aws-acm-patient-portal" }
}

resource "aws_route53_record" "patient_validation" {
  for_each = {
    for dvo in aws_acm_certificate.patient.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "patient" {
  certificate_arn         = aws_acm_certificate.patient.arn
  validation_record_fqdns = [for r in aws_route53_record.patient_validation : r.fqdn]
}


# ─────────────────────────────────────────────────────────
# 2. 의료진 포털 인증서 (Internal ALB용)
# ─────────────────────────────────────────────────────────
resource "aws_acm_certificate" "staff" {
  domain_name       = local.staff_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "aws-acm-staff-portal" }
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

  zone_id         = data.aws_route53_zone.main.zone_id
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


# ─────────────────────────────────────────────────────────
# 3. Wazuh 대시보드 인증서 (통합 ALB 추가 인증서)
# ─────────────────────────────────────────────────────────
resource "aws_acm_certificate" "wazuh" {
  domain_name       = local.wazuh_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "aws-acm-wazuh-dashboard" }
}

resource "aws_route53_record" "wazuh_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wazuh.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wazuh" {
  certificate_arn         = aws_acm_certificate.wazuh.arn
  validation_record_fqdns = [for r in aws_route53_record.wazuh_validation : r.fqdn]
}
