output "cloud_sql_private_ip" {
  description = "Cloud SQL Private IP (VPC 내부 접근용)"
  value       = google_sql_database_instance.main.private_ip_address
}

output "cloud_sql_connection_name" {
  description = "Cloud SQL 연결 이름 (Cloud Run 연결 시 사용)"
  value       = google_sql_database_instance.main.connection_name
}

output "db_app_password" {
  description = "앱 유저 비밀번호 → Vault secret/hospital/gcp-dr 에 저장"
  value       = random_password.db_password.result
  sensitive   = true
}

output "db_replication_password" {
  description = "pglogical 복제 유저 비밀번호 → Vault secret/hospital/gcp-dr 에 저장"
  value       = random_password.replication_password.result
  sensitive   = true
}
