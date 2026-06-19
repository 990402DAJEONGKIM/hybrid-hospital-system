# wazuh/lambda.tf

# Lambda 코드 zip 패키징
data "archive_file" "aws-wazuh-lambda-slack-notify" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_slack_notify.py"
  output_path = "${path.module}/lambda/lambda_slack_notify.zip"
}


# SNS → Lambda 권한 (wazuh-01)
resource "aws_lambda_permission" "aws-wazuh-lambda-sns-01" {
  statement_id  = "AllowSNSWazuh01"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws-wazuh-lambda-slack-notify.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.aws-wazuh-cw-alerts-01.arn
}

# SNS 구독 (wazuh-01)
resource "aws_sns_topic_subscription" "aws-wazuh-01-to-lambda" {
  topic_arn = aws_sns_topic.aws-wazuh-cw-alerts-01.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.aws-wazuh-lambda-slack-notify.arn
}


# ──────────────────────────────────────────
# wodle failover Lambda
# ──────────────────────────────────────────



resource "aws_lambda_function" "aws-wazuh-lambda-slack-notify" {
  function_name    = "aws-wazuh-lambda-slack-notify"
  role             = aws_iam_role.aws-wazuh-lambda-slack-notify-role.arn
  handler          = "lambda_slack_notify.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.aws-wazuh-lambda-slack-notify.output_path
  source_code_hash = data.archive_file.aws-wazuh-lambda-slack-notify.output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_PARAM = "/wazuh/slack-alarm-webhook"
    }
  }

  tags = {
    Name  = "aws-wazuh-lambda-slack-notify"
    Owner = "st2"
  }
}



# ──────────────────────────────────────────
# Agent 정리 Lambda
# 매일 새벽 3시 (KST) ecs-ec2 그룹
# disconnected Agent 자동 삭제
# ──────────────────────────────────────────
data "archive_file" "aws-wazuh-lambda-agent-cleanup" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_wazuh_agent_cleanup.py"
  output_path = "${path.module}/lambda/lambda_wazuh_agent_cleanup.zip"
}

resource "aws_lambda_function" "aws-wazuh-lambda-agent-cleanup" {
  function_name    = "aws-wazuh-lambda-agent-cleanup"
  role             = aws_iam_role.aws-wazuh-lambda-agent-cleanup-role.arn
  handler          = "lambda_wazuh_agent_cleanup.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.aws-wazuh-lambda-agent-cleanup.output_path
  source_code_hash = data.archive_file.aws-wazuh-lambda-agent-cleanup.output_base64sha256
  
  vpc_config {
    subnet_ids         = [data.aws_subnet.aws-app-sub-2a.id, data.aws_subnet.aws-app-sub-2b.id]
    security_group_ids = [aws_security_group.aws-wazuh-sg.id]
  }

  environment {
    variables = {
      # wazuh-01 IP: terraform이 EC2 생성 후 자동 주입
      WAZUH_API_URL           = "https://${aws_instance.aws-wazuh-01.private_ip}:55000"
      WAZUH_USER              = "wazuh"
      # 비밀번호는 Secrets Manager에서 가져옴 (하드코딩 금지)
      WAZUH_SECRET_NAME       = "aws-wazuh-api-password"
      REGION                  = var.aws_region
    }
  }

  tags = { Name = "aws-wazuh-lambda-agent-cleanup", Owner = "st2" }
}

# 매일 새벽 3시 KST (UTC 18:00) 실행
resource "aws_cloudwatch_event_rule" "aws-wazuh-lambda-agent-cleanup" {
  name                = "aws-wazuh-lambda-agent-cleanup"
  schedule_expression = "cron(0 18 * * ? *)"
  tags = { Name = "aws-wazuh-lambda-agent-cleanup", Owner = "st2" }
}

resource "aws_cloudwatch_event_target" "aws-wazuh-lambda-agent-cleanup" {
  rule = aws_cloudwatch_event_rule.aws-wazuh-lambda-agent-cleanup.name
  arn  = aws_lambda_function.aws-wazuh-lambda-agent-cleanup.arn
}

resource "aws_lambda_permission" "aws-wazuh-lambda-agent-cleanup-eventbridge" {
  statement_id  = "AllowEventBridgeAgentCleanup"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws-wazuh-lambda-agent-cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.aws-wazuh-lambda-agent-cleanup.arn
}

data "archive_file" "aws-wazuh-lambda-recovery" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_wazuh_recovery.py"
  output_path = "${path.module}/lambda/lambda_wazuh_recovery.zip"
}

resource "aws_lambda_function" "aws-wazuh-lambda-recovery" {
  function_name    = "aws-wazuh-lambda-recovery"
  role             = aws_iam_role.aws-wazuh-lambda-recovery-role.arn
  handler          = "lambda_wazuh_recovery.lambda_handler"
  runtime          = "python3.12"
  timeout          = 900
  filename         = data.archive_file.aws-wazuh-lambda-recovery.output_path
  source_code_hash = data.archive_file.aws-wazuh-lambda-recovery.output_base64sha256

  environment {
    variables = {
      TARGET_REGION     = var.aws_region
      SUBNET_ID         = data.aws_subnet.aws-app-sub-2a.id
      SECURITY_GROUP_ID = aws_security_group.aws-wazuh-sg.id
      INSTANCE_PROFILE  = aws_iam_instance_profile.aws-wazuh-profile.name
      FIXED_PRIVATE_IP  = var.wazuh_01_private_ip
      PLAYBOOK_PATH     = "/etc/ansible/wazuh"
    }
  }

  tags = { Name = "aws-wazuh-lambda-recovery", Owner = "st2" }
}


# Wazuh 매니저 EC2 중지/종료 즉시 감지 → Lambda + Slack - 수정 260616 김강환
# stopped/terminated만 잡음 → Reboot은 트리거 안 됨
resource "aws_cloudwatch_event_rule" "aws-wazuh-manager-ec2-stop" {
  name        = "aws-wazuh-manager-ec2-stop"
  description = "Wazuh Manager EC2 중지/종료 즉시 감지 — Lambda 재구축 트리거"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state       = ["stopped", "terminated"]
      instance-id = [aws_instance.aws-wazuh-01.id]
    }
  })

  tags = { Name = "aws-wazuh-manager-ec2-stop", Owner = "st2" }
}

# Lambda 트리거
resource "aws_cloudwatch_event_target" "aws-wazuh-manager-ec2-stop-lambda" {
  rule = aws_cloudwatch_event_rule.aws-wazuh-manager-ec2-stop.name
  arn  = aws_lambda_function.aws-wazuh-lambda-recovery.arn
}

# Slack 알림
resource "aws_cloudwatch_event_target" "aws-wazuh-manager-ec2-stop-slack" {
  rule = aws_cloudwatch_event_rule.aws-wazuh-manager-ec2-stop.name
  arn  = aws_sns_topic.aws-wazuh-cw-alerts-01.arn
}

# EventBridge → Lambda 권한
resource "aws_lambda_permission" "aws-wazuh-manager-ec2-stop-eventbridge" {
  statement_id  = "AllowEventBridgeManagerRecovery"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws-wazuh-lambda-recovery.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.aws-wazuh-manager-ec2-stop.arn
}

