#out.tf

output "cluster_name" {
  description = "ECS 클러스터 이름 (TC-ALB에서 참조)"
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ECS 클러스터 ARN"
  value       = aws_ecs_cluster.main.arn
}

output "ecs_ec2_sg_id" {
  description = "ECS EC2 보안 그룹 ID (ALB 모듈에서 inbound 규칙에 사용)"
  value       = aws_security_group.ecs_ec2.id
}

output "hospital_task_definition_arn" {
  description = "통합 병원 Task Definition ARN"
  value       = aws_ecs_task_definition.hospital.arn
}

output "asg_arn" {
  description = "ECS ASG ARN"
  value       = aws_autoscaling_group.ecs.arn
}
