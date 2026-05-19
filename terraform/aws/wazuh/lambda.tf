# wazuh/lambda.tf

# Lambda 코드 zip 패키징
data "archive_file" "slack_notify" {
  type        = "zip"
  source_file = "${path.module}/lambda/slack_notify.py"
  output_path = "${path.module}/lambda/slack_notify.zip"
}

# IAM Role
resource "aws_iam_role" "lambda_slack_notify" {
  name = "lambda-wazuh-slack-notify-role"

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
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_slack_notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda 함수
resource "aws_lambda_function" "slack_notify" {
  function_name    = "wazuh-slack-notify"
  role             = aws_iam_role.lambda_slack_notify.arn
  handler          = "slack_notify.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.slack_notify.output_path
  source_code_hash = data.archive_file.slack_notify.output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  tags = {
    Name  = "wazuh-slack-notify"
    Owner = "st2"
  }
}

# SNS → Lambda 권한 (wazuh-01)
resource "aws_lambda_permission" "sns_wazuh_01" {
  statement_id  = "AllowSNSWazuh01"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notify.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.aws-wazuh-alerts-01.arn
}

# SNS 구독 (wazuh-01)
resource "aws_sns_topic_subscription" "wazuh_01_to_lambda" {
  topic_arn = aws_sns_topic.aws-wazuh-alerts-01.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notify.arn
}