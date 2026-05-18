output "cluster_endpoint" {
  description = "Aurora 클러스터 Writer 엔드포인트"
  value       = aws_rds_cluster.main.endpoint
}

output "cluster_reader_endpoint" {
  description = "Aurora 클러스터 Reader 엔드포인트"
  value       = aws_rds_cluster.main.reader_endpoint
}

# output "proxy_endpoint" {
#   description = "RDS Proxy 엔드포인트 (App 서버 연결용)"
#   value       = aws_db_proxy.main.endpoint
# }

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
  value = aws_instance.aws_bastion_01[*].id # bastion 서버를 켜고 끄고 하는 variables 변수에 count 를 사용했으므로 
}

output "aws_rds_endpoint" {
  value = data.aws_rds_cluster.aws_aurora_01.endpoint
}
# =========================================================================================


# 뭄바이 RDS 복제용 (by 김다정 2026.05.18)
# =========================================================================================
output "hyderabad_rds_arn" {
  description = "Hyderabad RDS 클러스터 ARN"
  value       = aws_rds_cluster.main.arn
}

output "kms_key_arn" {
  description = "RDS 암호화 KMS Key ARN"
  value       = aws_kms_key.main.arn  # 팀원 코드의 실제 리소스명 확인 필요
}

output "rds_monitoring_role_arn" {
  description = "RDS 모니터링 IAM Role ARN"
  value       = aws_iam_role.rds_monitoring.arn  # 팀원 코드의 실제 리소스명 확인 필요
}
# =========================================================================================