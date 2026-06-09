output "dataset_id" {
  value       = google_bigquery_dataset.billing.dataset_id
  description = "BigQuery 데이터셋 ID"
}

output "dataset_location" {
  value       = google_bigquery_dataset.billing.location
  description = "BigQuery 데이터셋 위치"
}

output "wif_pool_name" {
  value       = google_iam_workload_identity_pool.aws_lambda.name
  description = "WIF 풀 전체 리소스 이름"
}

output "wif_provider_name" {
  value       = google_iam_workload_identity_pool_provider.aws_lambda.name
  description = "WIF 프로바이더 전체 리소스 이름"
}

output "billing_reader_sa_email" {
  value       = data.google_service_account.billing_reader.email
  description = "BigQuery 조회 서비스 계정 이메일"
}

# Lambda의 gcp_billing_collector에서 사용할 WIF credential config JSON
# SSM /mzclinic/cost/gcp/wif-config 에 저장
output "cf_url" {
  value       = google_cloudfunctions2_function.billing.service_config[0].uri
  description = "GCP Billing Reader Cloud Function URL"
}

output "wif_credential_config" {
  value = jsonencode({
    type                              = "external_account"
    audience                          = "//iam.googleapis.com/${google_iam_workload_identity_pool.aws_lambda.name}/providers/${google_iam_workload_identity_pool_provider.aws_lambda.workload_identity_pool_provider_id}"
    subject_token_type                = "urn:ietf:params:aws:token-type:aws4_request"
    token_url                         = "https://sts.googleapis.com/v1/token"
    credential_source = {
      environment_id             = "aws1"
      imds_v2_session_token_url  = "http://169.254.169.254/latest/api/token"
    }
    service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${data.google_service_account.billing_reader.email}:generateAccessToken"
  })
  description = "Lambda SSM /mzclinic/cost/gcp/wif-config 에 저장할 WIF 자격증명 설정 JSON"
  sensitive   = false
}
