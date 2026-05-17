output "vpc_id" {
  description = "뭄바이 VPC ID"
  value       = aws_vpc.mumbai.id
}

output "db_subnet_1a_id" {
  description = "DB 서브넷 1a ID"
  value       = aws_subnet.db_1a.id
}

output "db_subnet_1b_id" {
  description = "DB 서브넷 1b ID"
  value       = aws_subnet.db_1b.id
}

output "db_subnet_ids" {
  description = "DB 서브넷 ID 목록"
  value       = [aws_subnet.db_1a.id, aws_subnet.db_1b.id]
}

output "rds_security_group_id" {
  description = "RDS Security Group ID"
  value       = aws_security_group.rds.id
}

output "vpc_peering_id" {
  description = "VPC Peering Connection ID"
  value       = aws_vpc_peering_connection.hyderabad_to_mumbai.id
}

output "global_cluster_id" {
  description = "Aurora Global Cluster ID"
  value       = aws_rds_global_cluster.global.id
}

output "mumbai_rds_endpoint" {
  description = "뭄바이 Aurora 클러스터 엔드포인트"
  value       = aws_rds_cluster.mumbai_secondary.endpoint
}

output "mumbai_rds_reader_endpoint" {
  description = "뭄바이 Aurora 읽기 엔드포인트"
  value       = aws_rds_cluster.mumbai_secondary.reader_endpoint
}

output "mumbai_rds_arn" {
  description = "뭄바이 Aurora 클러스터 ARN"
  value       = aws_rds_cluster.mumbai_secondary.arn
}