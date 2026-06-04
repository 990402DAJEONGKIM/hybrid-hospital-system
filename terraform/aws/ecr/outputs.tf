# ─────────────────────────────────────────────────────────
# ECR 리포지토리 URL — ECS Task Definition에서 image 값으로 사용
# 형식: <account_id>.dkr.ecr.<region>.amazonaws.com/<repo_name>
# ─────────────────────────────────────────────────────────

output "nginx_repository_url" {
  description = "NGINX 리포지토리 URL"
  value       = aws_ecr_repository.repos["aws-hospital-nginx"].repository_url
}

output "api_repository_url" {
  description = "API 리포지토리 URL"
  value       = aws_ecr_repository.repos["aws-hospital-api"].repository_url
}

output "repository_urls" {
  description = "전체 리포지토리 URL 맵"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "registry_id" {
  description = "ECR 레지스트리 ID (= AWS 계정 ID)"
  value       = values(aws_ecr_repository.repos)[0].registry_id
}
