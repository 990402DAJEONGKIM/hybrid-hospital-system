resource "aws_appautoscaling_target" "ecs" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.hospital.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 1
  max_capacity       = 2
}

resource "aws_appautoscaling_policy" "ecs_alb" {
  name               = "hospital-alb-scaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    # 부하테스트 실측: 50명 → 분당 3,380건 / 태스크 1개
    # 80% 여유 적용 → 태스크당 2,700건 초과 시 scale out
    target_value = 2700

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${data.aws_lb.hospital.arn_suffix}/${data.aws_lb_target_group.hospital.arn_suffix}"
    }

    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}
