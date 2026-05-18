#cloudwatch.tf
data "aws_sns_topic" "aws-wazuh-alerts-01" {
  name = "aws-wazuh-alerts-01"
}

resource "aws_cloudwatch_metric_alarm" "aws-wazuh-status-02" {
  alarm_name          = "aws-wazuh-status-02"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-02.id
  }
  period              = 60
  evaluation_periods  = 2
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  alarm_actions       = [data.aws_sns_topic.aws-wazuh-alerts-01.arn]

  tags = {
    Name  = "aws-wazuh-status-02"
    Owner = "st2"
  }
}