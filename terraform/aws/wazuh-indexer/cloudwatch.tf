#cloudwatch.tf

# CloudWatch 알람 - 수정 260614 김강환
# ok_actions 추가: 인덱서 복구 완료 시 Slack 알림
resource "aws_cloudwatch_metric_alarm" "aws-wazuh-indexer-cw-status" {
  alarm_name          = "aws-wazuh-indexer-cw-status"
  namespace           = "Custom/Wazuh"
  metric_name         = "wazuh_indexer_up"
  dimensions          = { Role = "wazuh-indexer" }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  # notBreaching: EC2 소실 시 메트릭 안 와도 알람 발동 안 함
  # EC2 소실은 EventBridge가 처리
  # 프로세스만 죽었을 때만 Slack 발동
  treat_missing_data  = "notBreaching"
  alarm_actions = [data.terraform_remote_state.wazuh.outputs.wazuh_cw_alerts_sns_arn]
  ok_actions    = [data.terraform_remote_state.wazuh.outputs.wazuh_cw_alerts_sns_arn]
  tags = { Name = "aws-wazuh-indexer-cw-status", Owner = "st2" }
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



# EC2 중지/종료 즉시 감지 → Lambda + Slack - 수정 260616 김강환
# EventBridge로 EC2 상태 변화 실시간 감지
# stopped/terminated만 잡음 → Reboot은 트리거 안 됨
resource "aws_cloudwatch_event_rule" "aws-wazuh-indexer-ec2-stop" {
  name        = "aws-wazuh-indexer-ec2-stop"
  description = "Wazuh Indexer EC2 중지/종료 즉시 감지 — Lambda 재구축 트리거"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state       = ["stopped", "terminated"]
      instance-id = [aws_instance.aws-wazuh-indexer.id]
    }
  })

  tags = { Name = "aws-wazuh-indexer-ec2-stop", Owner = "st2" }
}


# Slack 알림
resource "aws_cloudwatch_event_target" "aws-wazuh-indexer-ec2-stop-slack" {
  rule = aws_cloudwatch_event_rule.aws-wazuh-indexer-ec2-stop.name
  arn  = data.terraform_remote_state.wazuh.outputs.wazuh_cw_alerts_sns_arn
}


resource "aws_cloudwatch_event_target" "aws-wazuh-indexer-ec2-stop-lambda" {
  rule = aws_cloudwatch_event_rule.aws-wazuh-indexer-ec2-stop.name
  arn  = aws_lambda_function.aws-wazuh-indexer-recovery.arn
}

resource "aws_lambda_permission" "aws-wazuh-indexer-ec2-stop-eventbridge" {
  statement_id  = "AllowEventBridgeIndexerRecovery"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws-wazuh-indexer-recovery.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.aws-wazuh-indexer-ec2-stop.arn
}