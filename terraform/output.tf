output "aws_bastion_01" {
  value = aws_instance.aws_bastion_01.id
}

output "aws_rds_endpoint" {
  value = data.aws_rds_cluster.aws_aurora_01.endpoint
}