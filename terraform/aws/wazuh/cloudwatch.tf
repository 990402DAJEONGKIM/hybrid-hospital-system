resource "aws_sns_topic" "aws-wazuh-alerts-01" {
  name = "aws-wazuh-alerts-01"
}


resource "aws_cloudwatch_metric_alarm" "aws-wazuh-recovery-01" {
  alarm_name          = "aws-wazuh-recovery-01"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-01.id
  }
  period              = 60
  evaluation_periods  = 2
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  alarm_actions = [
  "arn:aws:automate:${var.aws_region}:ec2:recover",
  aws_sns_topic.aws-wazuh-alerts-01.arn
  ]

  tags = {
    Name  = "aws-wazuh-recovery-01"
    Owner = "st2"
  }
}