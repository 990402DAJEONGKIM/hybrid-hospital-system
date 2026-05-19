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


# wazuh-indexer/cloudwatch.tf 하단 추가

data "aws_caller_identity" "current" {}

# SNS → Lambda 권한 (indexer)
resource "aws_lambda_permission" "aws-wazuh-sns-indexer" {
  statement_id  = "AllowSNSIndexer"
  action        = "lambda:InvokeFunction"
  function_name = "aws-wazuh-slack-notify"
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.aws-wazuh-indexer-alerts.arn
}

# SNS 구독 (indexer)
resource "aws_sns_topic_subscription" "aws-wazuh-indexer-to-lambda" {
  topic_arn = aws_sns_topic.aws-wazuh-indexer-alerts.arn
  protocol  = "lambda"
  endpoint  = "arn:aws:lambda:ap-south-2:${data.aws_caller_identity.current.account_id}:function:aws-wazuh-slack-notify"
  depends_on = [aws_lambda_permission.aws-wazuh-sns-indexer]
}