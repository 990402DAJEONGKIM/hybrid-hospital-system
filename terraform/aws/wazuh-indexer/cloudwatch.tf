#cloudwatch.tf
resource "aws_sns_topic" "aws-wazuh-indexer-cw-alerts" {
  name = "aws-wazuh-cw-indexer-alerts"
}

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
  alarm_actions       = [aws_sns_topic.aws-wazuh-indexer-cw-alerts.arn]

  tags = {
    Name  = "aws-wazuh-indexer-cw-status"
    Owner = "st2"
  }
}


# wazuh-indexer/cloudwatch.tf 하단 추가

data "aws_caller_identity" "current" {}

# SNS → Lambda 권한 (indexer)
resource "aws_lambda_permission" "aws-wazuh-lambda-sns-indexer" {
  statement_id  = "AllowSNSIndexer"
  action        = "lambda:InvokeFunction"
  function_name = "aws-wazuh-lambda-slack-notify"
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.aws-wazuh-indexer-cw-alerts.arn
}

# SNS 구독 (indexer)
resource "aws_sns_topic_subscription" "aws-wazuh-indexer-to-lambda" {
  topic_arn = aws_sns_topic.aws-wazuh-indexer-cw-alerts.arn
  protocol  = "lambda"
  endpoint  = "arn:aws:lambda:ap-south-2:${data.aws_caller_identity.current.account_id}:function:aws-wazuh-lambda-slack-notify"
  depends_on = [aws_lambda_permission.aws-wazuh-lambda-sns-indexer]
}

resource "aws_cloudwatch_metric_alarm" "aws-wazuh-indexer-cw-disk" {
  alarm_name          = "aws-wazuh-indexer-cw-disk"
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-indexer.id
    path       = "/"
    device     = "nvme0n1p1"
    fstype     = "ext4"
  }
  period              = 60
  evaluation_periods  = 3
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.aws-wazuh-indexer-cw-alerts.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-indexer-cw-alerts.arn]
  tags = { Name = "aws-wazuh-indexer-cw-disk", Owner = "st2" }
}

resource "aws_cloudwatch_metric_alarm" "aws-wazuh-indexer-cw-mem" {
  alarm_name          = "aws-wazuh-indexer-cw-mem"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  dimensions = {
    InstanceId = aws_instance.aws-wazuh-indexer.id
  }
  period              = 60
  evaluation_periods  = 3
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.aws-wazuh-indexer-cw-alerts.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-indexer-cw-alerts.arn]
  tags = { Name = "aws-wazuh-indexer-cw-mem", Owner = "st2" }
}