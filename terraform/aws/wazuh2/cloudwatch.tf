#cloudwatch.tf
data "aws_sns_topic" "aws-wazuh-cw-alerts-01" {
  name = "aws-wazuh-alerts-01"
}

resource "aws_cloudwatch_metric_alarm" "aws-wazuh-cw-status-02" {
  alarm_name          = "aws-wazuh-cw-status-02"
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
  alarm_actions       = [data.aws_sns_topic.aws-wazuh-cw-alerts-01.arn]

  tags = {
    Name  = "aws-wazuh-cw-status-02"
    Owner = "st2"
  }

}

# wazuh2/cloudwatch.tf 하단 추가

data "aws_caller_identity" "current" {}

# SNS → Lambda 권한 (wazuh-02)
resource "aws_lambda_permission" "aws-wazuh-lambda-sns-02" {
  statement_id  = "AllowSNSWazuh02"
  action        = "lambda:InvokeFunction"
  function_name = "aws-wazuh-lambda-slack-notify"
  principal     = "sns.amazonaws.com"
  source_arn    = data.aws_sns_topic.aws-wazuh-cw-alerts-01.arn
}

# SNS 구독 (wazuh-02)
resource "aws_sns_topic_subscription" "aws-wazuh-02-to-lambda" {
  topic_arn = data.aws_sns_topic.aws-wazuh-cw-alerts-01.arn
  protocol  = "lambda"
  endpoint  = "arn:aws:lambda:ap-south-2:${data.aws_caller_identity.current.account_id}:function:aws-wazuh-lambda-slack-notify"
  depends_on = [aws_lambda_permission.aws-wazuh-lambda-sns-02]
}

resource "aws_cloudwatch_metric_alarm" "aws-wazuh-cw-disk-02" {
  alarm_name          = "aws-wazuh-cw-disk-02"
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-02.id
    path       = "/"
    device     = "nvme0n1p1"
    fstype     = "ext4"
  }
  period              = 60
  evaluation_periods  = 3
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [data.aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  ok_actions          = [data.aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  tags = { Name = "aws-wazuh-cw-disk-02", Owner = "st2" }
}

# 메모리 알람 - wazuh-02
resource "aws_cloudwatch_metric_alarm" "aws-wazuh-cw-mem-02" {
  alarm_name          = "aws-wazuh-cw-mem-02"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-02.id
  }
  period              = 60
  evaluation_periods  = 3
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [data.aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  ok_actions          = [data.aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  tags = { Name = "aws-wazuh-cw-mem-02", Owner = "st2" }
}