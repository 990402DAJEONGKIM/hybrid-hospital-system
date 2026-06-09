output "bucket_name" {
  value       = data.terraform_remote_state.s3.outputs.storage_bucket_name
  description = "비용 데이터 S3 버킷"
}


output "chat_api_url" {
  value       = "${aws_api_gateway_stage.prod.invoke_url}/chat"
  description = "RAG 챗봇 API 엔드포인트"
}

output "chat_api_key_id" {
  value       = aws_api_gateway_api_key.cost_chat.id
  description = "API Gateway 키 ID (콘솔에서 값 확인)"
}

output "aws_account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "AWS 계정 ID"
}
