# wazuh/lambda.tf

# Lambda 코드 zip 패키징
data "archive_file" "aws-wazuh-slack-notify" {
  type        = "zip"
  source_file = "${path.module}/lambda/slack_notify.py"
  output_path = "${path.module}/lambda/slack_notify.zip"
}

# IAM Role
resource "aws_iam_role" "aws-wazuh-slack-notify-role" {
  name = "aws-wazuh-slack-notify-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# CloudWatch Logs 권한
resource "aws_iam_role_policy_attachment" "aws-wazuh-lambda-basic" {
  role       = aws_iam_role.aws-wazuh-slack-notify-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda 함수
resource "aws_lambda_function" "aws-wazuh-slack-notify" {
  function_name    = "aws-wazuh-slack-notify"
  role             = aws_iam_role.aws-wazuh-slack-notify-role.arn
  handler          = "slack_notify.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.aws-wazuh-slack-notify.output_path
  source_code_hash = data.archive_file.aws-wazuh-slack-notify.output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  tags = {
    Name  = "aws-wazuh-slack-notify"
    Owner = "st2"
  }
}

# SNS → Lambda 권한 (wazuh-01)
resource "aws_lambda_permission" "aws-wazuh-sns-01" {
  statement_id  = "AllowSNSWazuh01"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws-wazuh-slack-notify.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.aws-wazuh-alerts-01.arn
}

# SNS 구독 (wazuh-01)
resource "aws_sns_topic_subscription" "aws-wazuh-01-to-lambda" {
  topic_arn = aws_sns_topic.aws-wazuh-alerts-01.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.aws-wazuh-slack-notify.arn
}


# ──────────────────────────────────────────
# wodle failover Lambda
# ──────────────────────────────────────────

data "archive_file" "aws-wazuh-wodle-failover" {
  type        = "zip"
  source_file = "${path.module}/lambda/wodle_failover.py"
  output_path = "${path.module}/lambda/wodle_failover.zip"
}

resource "aws_iam_role" "aws-wazuh-wodle-failover-role" {
  name = "aws-wazuh-wodle-failover-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws-wazuh-wodle-failover-basic" {
  role       = aws_iam_role.aws-wazuh-wodle-failover-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "aws-wazuh-wodle-failover-policy" {
  name = "aws-wazuh-wodle-failover-policy"
  role = aws_iam_role.aws-wazuh-wodle-failover-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = ["cloudwatch:DescribeAlarms"]
        Resource = "*"
      },
      {
        Sid    = "SSMSendCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation"
        ]
        Resource = [
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
          data.terraform_remote_state.wazuh2.outputs.wazuh_instance_arn
        ]
      },
      {
        Sid    = "SSMParameter"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/wazuh/*"
      }
    ]
  })
}

resource "aws_lambda_function" "aws-wazuh-wodle-failover" {
  function_name    = "aws-wazuh-wodle-failover"
  role             = aws_iam_role.aws-wazuh-wodle-failover-role.arn
  handler          = "wodle_failover.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.aws-wazuh-wodle-failover.output_path
  source_code_hash = data.archive_file.aws-wazuh-wodle-failover.output_base64sha256

  environment {
    variables = {
      REGION               = var.aws_region
      WAZUH_01_INSTANCE_ID = aws_instance.aws-wazuh-01.id
      WAZUH_02_INSTANCE_ID = data.terraform_remote_state.wazuh2.outputs.wazuh_instance_id
      PARAM_KEY            = "/wazuh/wodle-active-server"
    }
  }

  tags = { Name = "aws-wazuh-wodle-failover", Owner = "st2" }
}

# EventBridge 1분마다 실행
resource "aws_cloudwatch_event_rule" "aws-wazuh-wodle-failover" {
  name                = "aws-wazuh-wodle-failover"
  schedule_expression = "rate(1 minute)"
  tags = { Name = "aws-wazuh-wodle-failover", Owner = "st2" }
}

resource "aws_cloudwatch_event_target" "aws-wazuh-wodle-failover" {
  rule = aws_cloudwatch_event_rule.aws-wazuh-wodle-failover.name
  arn  = aws_lambda_function.aws-wazuh-wodle-failover.arn
}

resource "aws_lambda_permission" "aws-wazuh-wodle-failover-eventbridge" {
  statement_id  = "AllowEventBridgeWodleFailover"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws-wazuh-wodle-failover.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.aws-wazuh-wodle-failover.arn
}