#cloudwatch.tf
resource "aws_sns_topic" "aws-wazuh-indexer-alerts" {
  name = "aws-wazuh-indexer-alerts"
}

resource "aws_cloudwatch_metric_alarm" "aws-wazuh-indexer-status" {
  alarm_name          = "aws-wazuh-indexer-status"
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
  alarm_actions       = [aws_sns_topic.aws-wazuh-indexer-alerts.arn]

  tags = {
    Name  = "aws-wazuh-indexer-status"
    Owner = "st2"
  }
}
