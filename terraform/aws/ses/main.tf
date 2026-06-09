# SES 샌드박스 모드에서는 수신자 이메일도 검증 필요
resource "aws_ses_email_identity" "admin" {
  email = var.admin_email
  tags  = local.common_tags
}

resource "aws_ses_email_identity" "alert" {
  count = var.alert_email != var.admin_email ? 1 : 0
  email = var.alert_email
  tags  = local.common_tags
}
