output "admin_email_arn" {
  value       = aws_ses_email_identity.admin.arn
  description = "관리자 이메일 SES identity ARN"
}

output "admin_email" {
  value       = var.admin_email
  description = "관리자 이메일 주소"
}

output "alert_email" {
  value       = var.alert_email
  description = "알림 이메일 주소"
}
