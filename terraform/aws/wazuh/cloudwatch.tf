#cloudwatch.tf

# SSM Parameter Store - Slack webhook
# SM에서 이전. KMS 암호화 동일, 비용 절감 (무료)
# 추가 260610 김강환

resource "aws_ssm_parameter" "aws-wazuh-slack-alarm-webhook" {
  name        = "/wazuh/slack-alarm-webhook"
  type        = "SecureString"
  key_id      = data.terraform_remote_state.kms.outputs.secretsmanager_kms_key_arn
  description = "CloudWatch 알람 → Slack 전송용 webhook (slack_notify Lambda)"
  value       = "PLACEHOLDER"  # 실제 값은 CLI로 덮어씀. state 평문 방지

  lifecycle {
    ignore_changes = [value]   # CLI 주입값 Terraform이 덮어쓰지 않게
  }

  tags = {
    Project     = "msp-hospital"
    Environment = "prod"
    Team        = "k2p"
    ManagedBy   = "terraform"
    Workspace   = "TC-aws-wazuh"
    Name        = "aws-wazuh-slack-alarm-webhook"
  }
}

resource "aws_ssm_parameter" "aws-wazuh-slack-report-webhook" {
  name        = "/wazuh/slack-report-webhook"
  type        = "SecureString"
  key_id      = data.terraform_remote_state.kms.outputs.secretsmanager_kms_key_arn
  description = "일일 보안 보고서 → Slack 전송용 webhook (report Lambda)"
  value       = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Project     = "msp-hospital"
    Environment = "prod"
    Team        = "k2p"
    ManagedBy   = "terraform"
    Workspace   = "TC-aws-wazuh"
    Name        = "aws-wazuh-slack-report-webhook"
  }
}




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
          StringEquals = { "AWS:SourceOwner" = data.aws_caller_identity.current.account_id }
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
    Role = "wazuh-manager"  # InstanceId → Role
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




# cloudwatch reboot/recover 알람 → SNS → Lambda → Slack 알림 흐름 구성
resource "aws_cloudwatch_metric_alarm" "aws-wazuh-cw-reboot-01" {
  alarm_name          = "aws-wazuh-cw-reboot-01"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions = { InstanceId = aws_instance.aws-wazuh-01.id }
  period              = 60
  evaluation_periods  = 3
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  alarm_actions       = ["arn:aws:automate:ap-south-2:ec2:reboot"]
  tags = { Name = "aws-wazuh-cw-reboot-01" }
}

resource "aws_cloudwatch_metric_alarm" "aws-wazuh-cw-recover-01" {
  alarm_name          = "aws-wazuh-cw-recover-01"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions = { InstanceId = aws_instance.aws-wazuh-01.id }
  period              = 60
  evaluation_periods  = 3
  statistic           = "Maximum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  alarm_actions       = ["arn:aws:automate:ap-south-2:ec2:recover"]
  tags = { Name = "aws-wazuh-cw-recover-01" }
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
  statistic           = "Maximum"
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0   
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