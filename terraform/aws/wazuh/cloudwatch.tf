#cloudwatch.tf
resource "aws_sns_topic" "aws-wazuh-alerts-01" {
  name = "aws-wazuh-alerts-01"
}


resource "aws_cloudwatch_metric_alarm" "aws-wazuh-status-01" {
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
  alarm_actions       = [aws_sns_topic.aws-wazuh-alerts-01.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-alerts-01.arn]
  tags = {
    Name  = "aws-wazuh-status-01"
    Owner = "st2"
  }
}


resource "aws_cloudwatch_metric_alarm" "aws-wazuh-disk-01" {
  alarm_name          = "aws-wazuh-disk-01"
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-01.id
    path       = "/"
    device     = "nvme0n1p1"
    fstype     = "ext4"
  }
  period              = 30
  evaluation_periods  = 3
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.aws-wazuh-alerts-01.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-alerts-01.arn]
  tags = { Name = "aws-wazuh-disk-01", Owner = "st2" }
}

resource "aws_cloudwatch_metric_alarm" "aws-wazuh-mem-01" {
  alarm_name          = "aws-wazuh-mem-01"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-01.id
  }
  period              = 60
  evaluation_periods  = 3
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.aws-wazuh-alerts-01.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-alerts-01.arn]
  tags = { Name = "aws-wazuh-mem-01", Owner = "st2" }
}

# wazuh-manager 프로세스 헬스체크 알람
resource "aws_cloudwatch_metric_alarm" "aws-wazuh-manager-01" {
  alarm_name          = "aws-wazuh-manager-01"
  namespace           = "Custom/Wazuh"
  metric_name         = "wazuh_manager_running"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-01.id
  }
  period              = 60
  evaluation_periods  = 2
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.aws-wazuh-alerts-01.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-alerts-01.arn]
  tags = { Name = "aws-wazuh-manager-01", Owner = "st2" }
}