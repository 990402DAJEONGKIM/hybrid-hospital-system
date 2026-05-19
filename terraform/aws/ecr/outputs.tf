# ─────────────────────────────────────────────────────────
# ECR 리포지토리 URL — ECS Task Definition에서 image 값으로 사용
# 형식: <account_id>.dkr.ecr.<region>.amazonaws.com/<repo_name>
# ─────────────────────────────────────────────────────────

output "nginx_patient_repository_url" {
  description = "NGINX Patient 리포지토리 URL"
  value       = aws_ecr_repository.repos["hospital-nginx-patient"].repository_url
}

output "api_patient_repository_url" {
  description = "API Patient 리포지토리 URL"
  value       = aws_ecr_repository.repos["hospital-api-patient"].repository_url
}

output "nginx_staff_repository_url" {
  description = "NGINX Staff 리포지토리 URL"
  value       = aws_ecr_repository.repos["hospital-nginx-staff"].repository_url
}

output "api_staff_repository_url" {
  description = "API Staff 리포지토리 URL"
  value       = aws_ecr_repository.repos["hospital-api-staff"].repository_url
}

output "repository_urls" {
  description = "전체 리포지토리 URL 맵 (ECS Task Definition 참조용)"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "registry_id" {
  description = "ECR 레지스트리 ID (= AWS 계정 ID)"
  value       = values(aws_ecr_repository.repos)[0].registry_id
}
