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

output "patient_domain" {
  description = "환자 포털 도메인"
  value       = var.patient_domain
}

output "staff_domain" {
  description = "의료진 포털 도메인"
  value       = var.staff_domain
}
