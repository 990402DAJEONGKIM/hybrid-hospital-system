#cloudwatch.tf
resource "aws_sns_topic" "aws-wazuh-cw-alerts-01" {
  name = "aws-wazuh-cw-alerts-01"
}


resource "aws_cloudwatch_metric_alarm" "aws-wazuh-cw-status-01" {
  alarm_name          = "aws-wazuh-status-01"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-01.id
  }
  period              = 60
  evaluation_periods  = 1
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "breaching" 
  alarm_actions       = [aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  tags = {
    Name  = "aws-wazuh-cw-status-01"
    Owner = "st2"
  }
}



# wazuh-manager 프로세스 헬스체크 알람
resource "aws_cloudwatch_metric_alarm" "aws-wazuh-cw-manager-01" {
  alarm_name          = "aws-wazuh-cw-manager-01"
  namespace           = "Custom/Wazuh"
  metric_name         = "wazuh_manager_running"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-01.id
  }
  period              = 30
  evaluation_periods  = 2
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  tags = { Name = "aws-wazuh-cw-manager-01", Owner = "st2" }
}