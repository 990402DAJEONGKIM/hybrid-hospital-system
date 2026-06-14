#cloudwatch.tf

# CloudWatch 알람 - 수정 260614 김강환
# ok_actions 추가: 인덱서 복구 완료 시 Slack 알림
resource "aws_cloudwatch_metric_alarm" "aws-wazuh-indexer-cw-status" {
  alarm_name          = "aws-wazuh-indexer-cw-status"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-indexer.id
  }
  period              = 60
  evaluation_periods  = 2
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  alarm_actions       = [data.terraform_remote_state.wazuh.outputs.wazuh_cw_alerts_sns_arn]
  ok_actions          = [data.terraform_remote_state.wazuh.outputs.wazuh_cw_alerts_sns_arn]
  tags = {
    Name  = "aws-wazuh-indexer-cw-status"
    Owner = "st2"
  }
}



# wazuh-indexer/cloudwatch.tf 하단 추가

data "aws_caller_identity" "current" {}




resource "aws_cloudwatch_metric_alarm" "aws-wazuh-indexer-reboot" {
  alarm_name          = "aws-wazuh-indexer-reboot"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-indexer.id
  }
  period              = 60
  evaluation_periods  = 3
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  alarm_actions = [
    "arn:aws:automate:${var.aws_region}:ec2:reboot"
  ]
  tags = { Name = "aws-wazuh-indexer-reboot" }
}

resource "aws_cloudwatch_metric_alarm" "aws-wazuh-indexer-recover" {
  alarm_name          = "aws-wazuh-indexer-recover"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-indexer.id
  }
  period              = 60
  evaluation_periods  = 3
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  alarm_actions = [
    "arn:aws:automate:${var.aws_region}:ec2:recover"
  ]
  tags = { Name = "aws-wazuh-indexer-recover" }
}



# ── 자동복구 2단: 서비스 다운/인스턴스 소실 트리거 ──
# 추가 260610 김강환
# 커스텀 메트릭이 0이거나 누락(인스턴스 사망)되면 발화
resource "aws_cloudwatch_metric_alarm" "aws-wazuh-indexer-service-down" {
  alarm_name          = "aws-wazuh-indexer-service-down"
  namespace           = "Custom/Wazuh"
  metric_name         = "wazuh_indexer_up"
  dimensions          = { Role = "wazuh-indexer" }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3            # 3분 연속 죽어야 발화(정상 재부팅 오발화 방지)
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"  # 메트릭 누락 = 인스턴스 소실 → 발화
  alarm_actions       = [aws_sns_topic.aws-wazuh-indexer-recovery.arn]

  tags = { Name = "aws-wazuh-indexer-service-down", Owner = "st2" }
}

# 재구축 Lambda 전용 SNS
resource "aws_sns_topic" "aws-wazuh-indexer-recovery" {
  name = "aws-wazuh-indexer-recovery"
}

resource "aws_lambda_permission" "aws-wazuh-indexer-recovery-sns" {
  statement_id  = "AllowSNSIndexerRecovery"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws-wazuh-indexer-recovery.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.aws-wazuh-indexer-recovery.arn
}

resource "aws_sns_topic_subscription" "aws-wazuh-indexer-recovery-sub" {
  topic_arn  = aws_sns_topic.aws-wazuh-indexer-recovery.arn
  protocol   = "lambda"
  endpoint   = aws_lambda_function.aws-wazuh-indexer-recovery.arn
  depends_on = [aws_lambda_permission.aws-wazuh-indexer-recovery-sns]
}