#cloudwatch.tf
resource "aws_sns_topic_policy" "aws-wazuh-cw-alerts-01" {
  arn = aws_sns_topic.aws-wazuh-cw-alerts-01.arn
  policy = jsonencode({
    Version = "2008-10-17"
    Id      = "__default_policy_ID"
    Statement = [
      {
        Sid    = "__default_statement_ID"
        Effect = "Allow"
        Principal = { AWS = "*" }
        Action = [
          "SNS:GetTopicAttributes",
          "SNS:SetTopicAttributes",
          "SNS:AddPermission",
          "SNS:RemovePermission",
          "SNS:DeleteTopic",
          "SNS:Subscribe",
          "SNS:ListSubscriptionsByTopic",
          "SNS:Publish"
        ]
        Resource = aws_sns_topic.aws-wazuh-cw-alerts-01.arn
        Condition = {
          StringEquals = { "AWS:SourceOwner" = "476293896981" }
        }
      },
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.aws-wazuh-cw-alerts-01.arn
      },
      {
        Sid    = "AllowEventBridge"
        Effect = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.aws-wazuh-cw-alerts-01.arn
      }
    ]
  })
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

resource "aws_sns_topic" "aws-wazuh-cw-alerts-01" {
  name = "aws-wazuh-cw-alerts-01"
}


# VPN OnPrem 터널 DOWN 알람
# 공식문서: https://docs.aws.amazon.com/vpn/latest/s2svpn/monitoring-overview-vpn.html
data "aws_vpn_connection" "aws-vpn-onprem-01" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpn-01"]
  }
}

data "aws_vpn_connection" "aws-vpn-gcp-01" {
  filter {
    name   = "tag:Name"
    values = ["aws-vpn-gcp"]
  }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-vpn-onprem-down-01" {
  alarm_name          = "aws-cw-vpn-onprem-down-01"
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  dimensions = {
    VpnId = data.aws_vpn_connection.aws-vpn-onprem-01.vpn_connection_id
  }
  period              = 60
  evaluation_periods  = 2
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  tags = { Name = "aws-cw-vpn-onprem-down-01" }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-vpn-gcp-down-01" {
  alarm_name          = "aws-cw-vpn-gcp-down-01"
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  dimensions = {
    VpnId = data.aws_vpn_connection.aws-vpn-gcp-01.vpn_connection_id
  }
  period              = 60
  evaluation_periods  = 2
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  ok_actions          = [aws_sns_topic.aws-wazuh-cw-alerts-01.arn]
  tags = { Name = "aws-cw-vpn-gcp-down-01" }
}