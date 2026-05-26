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

data "archive_file" "aws-wazuh-lambda-wodle-failover" {
  type        = "zip"
  source_file = "${path.module}/lambda/wodle_failover.py"
  output_path = "${path.module}/lambda/wodle_failover.zip"
}

resource "aws_lambda_function" "aws-wazuh-lambda-slack-notify" {
  function_name    = "aws-wazuh-lambda-slack-notify"
  role             = aws_iam_role.aws-wazuh-lambda-slack-notify-role.arn
  handler          = "slack_notify.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.aws-wazuh-lambda-slack-notify.output_path
  source_code_hash = data.archive_file.aws-wazuh-lambda-slack-notify.output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  tags = {
    Name  = "aws-wazuh-lambda-slack-notify"
    Owner = "st2"
  }
}


resource "aws_lambda_function" "aws-wazuh-lambda-wodle-failover" {
  function_name    = "aws-wazuh-lambda-wodle-failover"
  role             = aws_iam_role.aws-wazuh-lambda-wodle-failover-role.arn
  handler          = "wodle_failover.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.aws-wazuh-lambda-wodle-failover.output_path
  source_code_hash = data.archive_file.aws-wazuh-lambda-wodle-failover.output_base64sha256

  environment {
    variables = {
      REGION               = var.aws_region
      WAZUH_01_INSTANCE_ID = aws_instance.aws-wazuh-01.id
      WAZUH_02_INSTANCE_ID = data.terraform_remote_state.wazuh2.outputs.wazuh_instance_id
      PARAM_KEY            = "/wazuh/wodle-active-server"
    }
  }

  tags = { Name = "aws-wazuh-lambda-wodle-failover", Owner = "st2" }
}

# EventBridge 1분마다 실행
resource "aws_cloudwatch_event_rule" "aws-wazuh-lambda-wodle-failover" {
  name                = "aws-wazuh-lambda-wodle-failover"
  schedule_expression = "rate(1 minute)"
  tags = { Name = "aws-wazuh-lambda-wodle-failover", Owner = "st2" }
}

resource "aws_cloudwatch_event_target" "aws-wazuh-lambda-wodle-failover" {
  rule = aws_cloudwatch_event_rule.aws-wazuh-lambda-wodle-failover.name
  arn  = aws_lambda_function.aws-wazuh-lambda-wodle-failover.arn
}

resource "aws_lambda_permission" "aws-wazuh-lambda-wodle-failover-eventbridge" {
  statement_id  = "AllowEventBridgeWodleFailover"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws-wazuh-lambda-wodle-failover.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.aws-wazuh-lambda-wodle-failover.arn
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

  environment {
    variables = {
      # wazuh-01 IP: terraform이 EC2 생성 후 자동 주입
      WAZUH_API_URL           = "https://${aws_instance.aws-wazuh-01.private_ip}:55000"
      # wazuh-02 IP: wazuh2 workspace output에서 자동 참조
      WAZUH_API_URL_SECONDARY = "https://${data.terraform_remote_state.wazuh2.outputs.wazuh_private_ip}:55000"
      WAZUH_USER              = "wazuh"
      # 비밀번호는 Secrets Manager에서 가져옴 (하드코딩 금지)
      WAZUH_SECRET_NAME       = "wazuh/api-password"
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