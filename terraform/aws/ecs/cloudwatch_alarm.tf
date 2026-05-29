# =========================================================
# cloudwatch_alarm.tf — rotation 실패 시 이메일 알람
#
# 흐름:
#   Lambda 에러 발생
#     → CloudWatch 에러 메트릭 증가
#     → Alarm 임계값 초과
#     → SNS Topic
#     → 이메일 발송
# =========================================================


# ── SNS Topic ─────────────────────────────────────────────
# 알람 메시지를 받아서 구독자(이메일)에게 전달하는 채널
resource "aws_sns_topic" "rotation_alert" {
  name = "aws-sns-rotation-alert"                             # SNS 토픽 이름
  tags = merge(local.common_tags, { Name = "aws-sns-rotation-alert" })
}

# 이메일 구독 — 토픽에 메시지 오면 이 주소로 발송
# apply 후 해당 이메일로 확인 메일이 오므로 반드시 수락 클릭 필요
resource "aws_sns_topic_subscription" "rotation_alert_email" {
  topic_arn = aws_sns_topic.rotation_alert.arn   # 위에서 만든 SNS 토픽
  protocol  = "email"                             # 발송 방식: 이메일
  endpoint  = var.alert_email                     # 수신 이메일 주소 (variables.tf)
}


# ── ecs_db_rotator 에러 알람 ───────────────────────────────
# RDS 비밀번호 변경 Lambda가 실패했을 때 알림
resource "aws_cloudwatch_metric_alarm" "db_rotator_error" {
  alarm_name          = "aws-alarm-ecs-db-rotator-error"      # 알람 이름
  alarm_description   = "RDS 비밀번호 rotation Lambda 실패"    # 설명
  comparison_operator = "GreaterThanOrEqualToThreshold"       # 임계값 이상이면 알람
  threshold           = 1                                     # 에러 1회 이상이면 발동
  evaluation_periods  = 1                                     # 1개 구간 연속 초과 시 알람
  period              = 60                                    # 측정 구간: 60초
  metric_name         = "Errors"                              # Lambda 에러 메트릭
  namespace           = "AWS/Lambda"                          # Lambda 메트릭 네임스페이스
  statistic           = "Sum"                                 # 구간 내 에러 합산

  dimensions = {
    FunctionName = aws_lambda_function.ecs_db_rotator.function_name  # 감시할 Lambda
  }

  alarm_actions = [aws_sns_topic.rotation_alert.arn]          # 알람 발동 시 SNS 전송
  tags = merge(local.common_tags, { Name = "aws-alarm-ecs-db-rotator-error" })
}


# ── ecs_redeployer 에러 알람 ───────────────────────────────
# ECS 재배포 Lambda가 실패했을 때 알림
resource "aws_cloudwatch_metric_alarm" "redeployer_error" {
  alarm_name          = "aws-alarm-ecs-redeployer-error"      # 알람 이름
  alarm_description   = "ECS 재배포 Lambda 실패"               # 설명
  comparison_operator = "GreaterThanOrEqualToThreshold"       # 임계값 이상이면 알람
  threshold           = 1                                     # 에러 1회 이상이면 발동
  evaluation_periods  = 1                                     # 1개 구간 연속 초과 시 알람
  period              = 60                                    # 측정 구간: 60초
  metric_name         = "Errors"                              # Lambda 에러 메트릭
  namespace           = "AWS/Lambda"                          # Lambda 메트릭 네임스페이스
  statistic           = "Sum"                                 # 구간 내 에러 합산

  dimensions = {
    FunctionName = aws_lambda_function.ecs_redeployer.function_name  # 감시할 Lambda
  }

  alarm_actions = [aws_sns_topic.rotation_alert.arn]          # 알람 발동 시 SNS 전송
  tags = merge(local.common_tags, { Name = "aws-alarm-ecs-redeployer-error" })
}
