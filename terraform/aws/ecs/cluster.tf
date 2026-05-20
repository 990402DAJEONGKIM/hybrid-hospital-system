# =========================================================
# ECS Cluster + Capacity Provider
# =========================================================

resource "aws_ecs_cluster" "main" {
  name = "aws-ecs-cluster-01"

  # Container Insights: CloudWatch 메트릭 수집 (ISMS-P 2.9.1)
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}


# ─────────────────────────────────────────────────────────
# Capacity Provider — ASG와 ECS 클러스터를 연결
# Managed Scaling: ECS 태스크 수요에 따라 EC2 자동 증감
# ─────────────────────────────────────────────────────────
resource "aws_ecs_capacity_provider" "main" {
  name = "k2p-ecs-capacity-provider-01"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs.arn

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 80   # EC2 용량 80% 목표 (버퍼 20% 유지)
      minimum_scaling_step_size = 2    # 트래픽 급증 시 2대씩 추가 (1→3)
      maximum_scaling_step_size = 2
    }

    managed_termination_protection = "ENABLED"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 0
  }
}
