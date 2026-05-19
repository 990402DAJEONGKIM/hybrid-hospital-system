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

# wazuh2/cloudwatch.tf 하단 추가

data "aws_caller_identity" "current" {}

# SNS → Lambda 권한 (wazuh-02)
resource "aws_lambda_permission" "sns_wazuh_02" {
  statement_id  = "AllowSNSWazuh02"
  action        = "lambda:InvokeFunction"
  function_name = "wazuh-slack-notify"
  principal     = "sns.amazonaws.com"
  source_arn    = data.aws_sns_topic.aws-wazuh-alerts-01.arn
}

# SNS 구독 (wazuh-02)
resource "aws_sns_topic_subscription" "wazuh_02_to_lambda" {
  topic_arn = data.aws_sns_topic.aws-wazuh-alerts-01.arn
  protocol  = "lambda"
  endpoint  = "arn:aws:lambda:ap-south-2:${data.aws_caller_identity.current.account_id}:function:wazuh-slack-notify"
}