# 2026-06-11 Sean: setup-cost-config.sh가 읽을 비용 분석 API 접속 정보를 SSM Parameter Store에 저장
# 주의: aws_api_gateway_api_key.cost_chat.value는 Terraform state에도 저장됩니다.
#       현재처럼 Terraform Cloud에서만 실행하고 state 접근 권한을 제한하는 전제로 사용하세요.

resource "aws_ssm_parameter" "cost_chat_api_url" {
  name        = "/mzclinic/cost/chat/api-url"
  description = "Cost analysis chat API Gateway endpoint"
  type        = "String"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/chat"
  tags = merge(local.common_tags, { Name = "aws-ssm-cost-chat-api-url" })
}

resource "aws_ssm_parameter" "cost_chat_api_key" {
  name        = "/mzclinic/cost/chat/api-key"
  description = "Cost analysis API Gateway key for admin_chat.html deployment"
  type        = "SecureString"
  value       = aws_api_gateway_api_key.cost_chat.value
  tags = merge(local.common_tags, { Name = "aws-ssm-cost-chat-api-key" })
}

resource "aws_ssm_parameter" "usd_krw_rate_cache" {
  name        = "/mzclinic/cost/exim/usd-krw-cache"
  description = "USD/KRW 환율 일별 캐시 — Lambda가 자동 갱신 (형식: 환율:YYYY-MM-DD)"
  type        = "String"
  value       = "1400.0:1970-01-01"
  tags        = merge(local.common_tags, { Name = "aws-ssm-cost-usd-krw-cache" })

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "msp_monthly_fee" {
  name        = "/mzclinic/cost/msp/monthly-fee"
  description = "MSP 운영 대행 월 계약금 (원) — AWS/GCP/온프레미스 통합 관리"
  type        = "String"
  value       = tostring(var.msp_monthly_fee)
  overwrite   = true
  tags        = merge(local.common_tags, { Name = "aws-ssm-cost-msp-monthly-fee" })
}