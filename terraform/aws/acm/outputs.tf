# ─────────────────────────────────────────────────────────
# ACM 인증서 ARN — ALB HTTPS 리스너에서 참조
# TC-ALB 워크스페이스에서 이 output을 사용
# ─────────────────────────────────────────────────────────

output "patient_certificate_arn" {
  description = "환자 포털 인증서 ARN (Public ALB HTTPS 리스너용)"
  value       = aws_acm_certificate_validation.patient.certificate_arn
}

output "staff_certificate_arn" {
  description = "의료진 포털 인증서 ARN (Internal ALB HTTPS 리스너용)"
  value       = aws_acm_certificate_validation.staff.certificate_arn
}

# 2026-06-02 통합 ALB 추가 인증서 ARN output — 김강환
output "grafana_certificate_arn" {
  description = "Grafana 대시보드 인증서 ARN (staff-alb SNI용)"
  value       = aws_acm_certificate_validation.grafana.certificate_arn
}

# admin_certificate_arn 삭제 — admin.mzclinic.cloud 제거, staff로 통합
# output "admin_certificate_arn" {
#   description = "관리자 포털 인증서 ARN (staff-alb SNI용)"
#   value       = aws_acm_certificate_validation.admin.certificate_arn
# }

output "patient_domain" {
  description = "환자 포털 도메인"
  value       = local.patient_domain
}

output "staff_domain" {
  description = "의료진 포털 도메인"
  value       = local.staff_domain
}


