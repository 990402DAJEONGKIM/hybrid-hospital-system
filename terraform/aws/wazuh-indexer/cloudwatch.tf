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

