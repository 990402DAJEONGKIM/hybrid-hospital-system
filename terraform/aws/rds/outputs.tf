output "cluster_endpoint" {
  description = "Aurora 클러스터 Writer 엔드포인트"
  value       = aws_rds_cluster.main.endpoint
}

output "cluster_reader_endpoint" {
  description = "Aurora 클러스터 Reader 엔드포인트"
  value       = aws_rds_cluster.main.reader_endpoint
}

output "proxy_endpoint" {
  description = "RDS Proxy Writer 엔드포인트 — INSERT/UPDATE/DELETE 전용"
  value       = aws_db_proxy.main.endpoint
}

output "proxy_reader_endpoint" {
  description = "RDS Proxy Reader 엔드포인트 — SELECT 전용"
  value       = aws_db_proxy_endpoint.reader.endpoint
}

output "cluster_id" {
  description = "Aurora 클러스터 ID"
  value       = aws_rds_cluster.main.id
}

output "sg_proxy_id" {
  description = "Proxy 보안 그룹 ID"
  value       = aws_security_group.proxy.id
}

output "sg_rds_id" {
  description = "RDS 보안 그룹 ID"
  value       = aws_security_group.rds.id
}

output "db_subnet_group_name" {
  description = "DB 서브넷 그룹 이름"
  value       = aws_db_subnet_group.main.name
}

output "stop_command" {
  description = "클러스터 중지 명령어"
  value       = "aws rds stop-db-cluster --db-cluster-identifier ${aws_rds_cluster.main.id} --region ${var.aws_region}"
}

output "start_command" {
  description = "클러스터 시작 명령어"
  value       = "aws rds start-db-cluster --db-cluster-identifier ${aws_rds_cluster.main.id} --region ${var.aws_region}"
}

# bastion host 용 (by 김다정 2026.05.13)
# =========================================================================================
output "aws_bastion_01" {
  value = aws_instance.aws_bastion_01.id 
}

output "aws_rds_endpoint" {
  value = data.aws_rds_cluster.aws_aurora_01.endpoint
}
# =========================================================================================
