# =========================================================
# 멀티클라우드 비용 분석 RAG — 루트 모듈
# =========================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_route53_zone" "mzclinic" {
  name         = "mzclinic.cloud."
  private_zone = false
}


# ---------------------------------------------------------
# IAM — Lambda 공통 실행 역할
# ---------------------------------------------------------
resource "aws_iam_role" "lambda_exec" {
  name = "aws-cost-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "lambda_exec" {
  name = "aws-cost-lambda-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/aws-lambda-cost-*:*"
      },
      {
        Sid    = "S3ReadWrite"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          data.terraform_remote_state.s3.outputs.storage_bucket_arn,
          "${data.terraform_remote_state.s3.outputs.storage_bucket_arn}/cost/*",
        ]
      },
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/mzclinic/cost/*"
      },
      {
        Sid      = "KMS"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.aws_kms_key.s3.arn
      },
      {
        Sid      = "Bedrock"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "*"
      },
      {
        Sid    = "SES"
        Effect = "Allow"
        Action = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Sid    = "CostExplorer"
        Effect = "Allow"
        Action = ["ce:GetCostAndUsage"]
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------
# Lambda Layer — reportlab (PDF 생성용)
# ---------------------------------------------------------
resource "aws_lambda_layer_version" "reportlab" {
  layer_name          = "aws-cost-reportlab"
  filename            = "${path.module}/lambda/reportlab_layer.zip"
  source_code_hash    = filebase64sha256("${path.module}/lambda/reportlab_layer.zip")
  compatible_runtimes = ["python3.12"]
  description         = "reportlab 4.2.5 — monthly_report PDF 생성용"
}

# ---------------------------------------------------------
# Lambda — AWS Cost Collector
# ---------------------------------------------------------
data "archive_file" "aws_cost_collector" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/aws_cost_collector"
  output_path = "${path.module}/lambda/aws_cost_collector.zip"
}

resource "aws_cloudwatch_log_group" "aws_cost_collector" {
  name              = "/aws/lambda/aws-lambda-cost-aws-collector"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-aws-collector" })
}

resource "aws_lambda_function" "aws_cost_collector" {
  function_name    = "aws-lambda-cost-aws-collector"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 128
  filename         = data.archive_file.aws_cost_collector.output_path
  source_code_hash = data.archive_file.aws_cost_collector.output_base64sha256

  environment {
    variables = {
      RAW_BUCKET = data.terraform_remote_state.s3.outputs.storage_bucket_name
    }
  }

  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-aws-collector" })
  depends_on = [aws_cloudwatch_log_group.aws_cost_collector]
}

# ---------------------------------------------------------
# Lambda — GCP Billing Collector
# ---------------------------------------------------------
data "archive_file" "gcp_billing_collector" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/gcp_billing_collector"
  output_path = "${path.module}/lambda/gcp_billing_collector.zip"
}

resource "aws_cloudwatch_log_group" "gcp_billing_collector" {
  name              = "/aws/lambda/aws-lambda-cost-gcp-collector"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-gcp-collector" })
}

resource "aws_lambda_function" "gcp_billing_collector" {
  function_name    = "aws-lambda-cost-gcp-collector"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.gcp_billing_collector.output_path
  source_code_hash = data.archive_file.gcp_billing_collector.output_base64sha256
  environment {
    variables = {
      RAW_BUCKET    = data.terraform_remote_state.s3.outputs.storage_bucket_name
      SSM_GCP_CF_URL = "/mzclinic/cost/gcp/cf-url"
      SSM_GCP_CF_KEY = "/mzclinic/cost/gcp/cf-api-key"
    }
  }

  depends_on = [aws_cloudwatch_log_group.gcp_billing_collector]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-gcp-collector" })
}

# ---------------------------------------------------------
# Lambda — OnPrem Cost Calculator
# ---------------------------------------------------------
data "archive_file" "onprem_cost_calculator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/onprem_cost_calculator"
  output_path = "${path.module}/lambda/onprem_cost_calculator.zip"
}

resource "aws_cloudwatch_log_group" "onprem_cost_calculator" {
  name              = "/aws/lambda/aws-lambda-cost-onprem-calc"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-onprem-calc" })
}

resource "aws_lambda_function" "onprem_cost_calculator" {
  function_name    = "aws-lambda-cost-onprem-calc"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 128
  filename         = data.archive_file.onprem_cost_calculator.output_path
  source_code_hash = data.archive_file.onprem_cost_calculator.output_base64sha256

  environment {
    variables = {
      RAW_BUCKET      = data.terraform_remote_state.s3.outputs.storage_bucket_name
      SSM_COST_PARAMS = "/mzclinic/cost/onprem/cost-params"
    }
  }

  depends_on = [aws_cloudwatch_log_group.onprem_cost_calculator]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-onprem-calc" })
}

# ---------------------------------------------------------
# Lambda — Cost to Knowledge Base
# ---------------------------------------------------------
data "archive_file" "cost_to_kb" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/cost_to_kb"
  output_path = "${path.module}/lambda/cost_to_kb.zip"
}

resource "aws_cloudwatch_log_group" "cost_to_kb" {
  name              = "/aws/lambda/aws-lambda-cost-to-kb"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-to-kb" })
}

resource "aws_lambda_function" "cost_to_kb" {
  function_name    = "aws-lambda-cost-to-kb"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.cost_to_kb.output_path
  source_code_hash = data.archive_file.cost_to_kb.output_base64sha256

  environment {
    variables = {
      RAW_BUCKET        = data.terraform_remote_state.s3.outputs.storage_bucket_name
      CHUNKS_BUCKET     = data.terraform_remote_state.s3.outputs.storage_bucket_name
      ANNUAL_BUDGET_KRW = tostring(var.annual_budget_krw)
      SSM_EXIM_API_KEY  = "/mzclinic/cost/exim/api-key"
    }
  }

  depends_on = [aws_cloudwatch_log_group.cost_to_kb]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-to-kb" })
}

# ---------------------------------------------------------
# Lambda — Monthly Report
# ---------------------------------------------------------
data "archive_file" "monthly_report" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/monthly_report"
  output_path = "${path.module}/lambda/monthly_report.zip"
}

resource "aws_cloudwatch_log_group" "monthly_report" {
  name              = "/aws/lambda/aws-lambda-cost-monthly-report"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-monthly-report" })
}

resource "aws_lambda_function" "monthly_report" {
  function_name    = "aws-lambda-cost-monthly-report"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 600
  memory_size      = 512
  filename         = data.archive_file.monthly_report.output_path
  source_code_hash = data.archive_file.monthly_report.output_base64sha256
  layers           = [aws_lambda_layer_version.reportlab.arn]

  environment {
    variables = {
      CHUNKS_BUCKET  = data.terraform_remote_state.s3.outputs.storage_bucket_name
      BEDROCK_REGION = var.bedrock_region
      ADMIN_EMAIL    = var.admin_email
      FROM_EMAIL     = "no-reply@mzclinic.cloud"
      SES_REGION     = var.aws_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.monthly_report, aws_lambda_layer_version.reportlab]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-monthly-report" })
}

# ---------------------------------------------------------
# Lambda — Cost Chat (RAG)
# ---------------------------------------------------------
data "archive_file" "cost_chat" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/cost_chat"
  output_path = "${path.module}/lambda/cost_chat.zip"
}

resource "aws_cloudwatch_log_group" "cost_chat" {
  name              = "/aws/lambda/aws-lambda-cost-chat"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-chat" })
}

resource "aws_lambda_function" "cost_chat" {
  function_name    = "aws-lambda-cost-chat"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.cost_chat.output_path
  source_code_hash = data.archive_file.cost_chat.output_base64sha256

  environment {
    variables = {
      CHUNKS_BUCKET  = data.terraform_remote_state.s3.outputs.storage_bucket_name
      BEDROCK_REGION = var.bedrock_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.cost_chat]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-chat" })
}

# ---------------------------------------------------------
# Lambda — Anomaly Detector
# ---------------------------------------------------------
data "archive_file" "anomaly_detector" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/anomaly_detector"
  output_path = "${path.module}/lambda/anomaly_detector.zip"
}

resource "aws_cloudwatch_log_group" "anomaly_detector" {
  name              = "/aws/lambda/aws-lambda-cost-anomaly"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-anomaly" })
}

resource "aws_lambda_function" "anomaly_detector" {
  function_name    = "aws-lambda-cost-anomaly"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 128
  filename         = data.archive_file.anomaly_detector.output_path
  source_code_hash = data.archive_file.anomaly_detector.output_base64sha256

  environment {
    variables = {
      BUCKET      = data.terraform_remote_state.s3.outputs.storage_bucket_name
      ALERT_EMAIL = var.alert_email
      FROM_EMAIL  = "no-reply@mzclinic.cloud"
      SES_REGION  = var.aws_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.anomaly_detector]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-anomaly" })
}

# ---------------------------------------------------------
# Lambda — Cost Dashboard
# ---------------------------------------------------------
data "archive_file" "cost_dashboard" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/cost_dashboard"
  output_path = "${path.module}/lambda/cost_dashboard.zip"
}

resource "aws_cloudwatch_log_group" "cost_dashboard" {
  name              = "/aws/lambda/aws-lambda-cost-dashboard"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-dashboard" })
}

resource "aws_lambda_function" "cost_dashboard" {
  function_name    = "aws-lambda-cost-dashboard"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.cost_dashboard.output_path
  source_code_hash = data.archive_file.cost_dashboard.output_base64sha256

  environment {
    variables = {
      RAW_BUCKET         = data.terraform_remote_state.s3.outputs.storage_bucket_name
      ANNUAL_BUDGET_KRW  = var.annual_budget_krw
    }
  }

  depends_on = [aws_cloudwatch_log_group.cost_dashboard]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-dashboard" })
}

# ---------------------------------------------------------
# API Gateway — RAG 챗봇 엔드포인트
# ---------------------------------------------------------
resource "aws_api_gateway_rest_api" "cost_chat" {
  name        = "aws-apigw-cost-chat"
  description = "멀티클라우드 비용 RAG 챗봇 API"
  tags        = local.common_tags
}

resource "aws_api_gateway_resource" "chat" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  parent_id   = aws_api_gateway_rest_api.cost_chat.root_resource_id
  path_part   = "chat"
}

resource "aws_api_gateway_method" "chat_post" {
  rest_api_id      = aws_api_gateway_rest_api.cost_chat.id
  resource_id      = aws_api_gateway_resource.chat.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_method" "chat_options" {
  rest_api_id   = aws_api_gateway_rest_api.cost_chat.id
  resource_id   = aws_api_gateway_resource.chat.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "chat_post" {
  rest_api_id             = aws_api_gateway_rest_api.cost_chat.id
  resource_id             = aws_api_gateway_resource.chat.id
  http_method             = aws_api_gateway_method.chat_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.cost_chat.invoke_arn
}

resource "aws_api_gateway_integration" "chat_options" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.chat.id
  http_method = aws_api_gateway_method.chat_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "chat_options_200" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.chat.id
  http_method = aws_api_gateway_method.chat_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "chat_options" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.chat.id
  http_method = aws_api_gateway_method.chat_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_lambda_permission" "apigw_cost_chat" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_chat.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.cost_chat.execution_arn}/*/*"
}

# /dashboard 리소스
resource "aws_api_gateway_resource" "dashboard" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  parent_id   = aws_api_gateway_rest_api.cost_chat.root_resource_id
  path_part   = "dashboard"
}

resource "aws_api_gateway_method" "dashboard_get" {
  rest_api_id      = aws_api_gateway_rest_api.cost_chat.id
  resource_id      = aws_api_gateway_resource.dashboard.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_method" "dashboard_options" {
  rest_api_id   = aws_api_gateway_rest_api.cost_chat.id
  resource_id   = aws_api_gateway_resource.dashboard.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "dashboard_get" {
  rest_api_id             = aws_api_gateway_rest_api.cost_chat.id
  resource_id             = aws_api_gateway_resource.dashboard.id
  http_method             = aws_api_gateway_method.dashboard_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.cost_dashboard.invoke_arn
}

resource "aws_api_gateway_integration" "dashboard_options" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.dashboard.id
  http_method = aws_api_gateway_method.dashboard_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "dashboard_options_200" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.dashboard.id
  http_method = aws_api_gateway_method.dashboard_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "dashboard_options" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.dashboard.id
  http_method = aws_api_gateway_method.dashboard_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_method_response.dashboard_options_200]
}

resource "aws_lambda_permission" "apigw_cost_dashboard" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_dashboard.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.cost_chat.execution_arn}/*/*"
}

# /report 리소스
resource "aws_api_gateway_resource" "report" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  parent_id   = aws_api_gateway_rest_api.cost_chat.root_resource_id
  path_part   = "report"
}

resource "aws_api_gateway_method" "report_post" {
  rest_api_id      = aws_api_gateway_rest_api.cost_chat.id
  resource_id      = aws_api_gateway_resource.report.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_method" "report_options" {
  rest_api_id   = aws_api_gateway_rest_api.cost_chat.id
  resource_id   = aws_api_gateway_resource.report.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "report_post" {
  rest_api_id             = aws_api_gateway_rest_api.cost_chat.id
  resource_id             = aws_api_gateway_resource.report.id
  http_method             = aws_api_gateway_method.report_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.monthly_report.invoke_arn
}

resource "aws_api_gateway_integration" "report_options" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.report.id
  http_method = aws_api_gateway_method.report_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "report_options_200" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.report.id
  http_method = aws_api_gateway_method.report_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "report_options" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.report.id
  http_method = aws_api_gateway_method.report_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_method_response.report_options_200]
}

resource "aws_lambda_permission" "apigw_monthly_report" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.monthly_report.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.cost_chat.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "cost_chat" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id

  depends_on = [
    aws_api_gateway_integration.chat_post,
    aws_api_gateway_integration.chat_options,
    aws_api_gateway_integration.dashboard_get,
    aws_api_gateway_integration.dashboard_options,
    aws_api_gateway_integration.report_post,
    aws_api_gateway_integration.report_options,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.cost_chat.id
  deployment_id = aws_api_gateway_deployment.cost_chat.id
  stage_name    = "prod"
  tags          = local.common_tags
}

resource "aws_api_gateway_api_key" "cost_chat" {
  name = "aws-cost-chat-key"
  tags = local.common_tags
}

resource "aws_api_gateway_usage_plan" "cost_chat" {
  name = "aws-cost-chat-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.cost_chat.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  tags = local.common_tags
}

resource "aws_api_gateway_usage_plan_key" "cost_chat" {
  key_id        = aws_api_gateway_api_key.cost_chat.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.cost_chat.id
}

# ---------------------------------------------------------
# EventBridge Scheduler — 공통 실행 역할
# ---------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name = "aws-cost-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "scheduler" {
  name = "aws-cost-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "lambda:InvokeFunction"
      Resource = [
        aws_lambda_function.aws_cost_collector.arn,
        aws_lambda_function.gcp_billing_collector.arn,
        aws_lambda_function.onprem_cost_calculator.arn,
        aws_lambda_function.cost_to_kb.arn,
        aws_lambda_function.anomaly_detector.arn,
        aws_lambda_function.monthly_report.arn,
      ]
    }]
  })
}

# ---------------------------------------------------------
# EventBridge Schedules
# ---------------------------------------------------------
resource "aws_scheduler_schedule" "aws_cost_collector" {
  name        = "aws-sch-cost-aws-collector"
  description = "AWS 서비스별 비용 수집 — 매일 01:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 16 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.aws_cost_collector.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "gcp_billing_collector" {
  name        = "aws-sch-cost-gcp-collector"
  description = "GCP 빌링 데이터 수집 — 매일 01:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 16 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.gcp_billing_collector.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "onprem_cost_calculator" {
  name        = "aws-sch-cost-onprem-calc"
  description = "온프레미스 비용 계산 — 매일 01:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 16 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.onprem_cost_calculator.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "cost_to_kb" {
  name        = "aws-sch-cost-to-kb"
  description = "Knowledge Base 업데이트 — 매일 02:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 17 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.cost_to_kb.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "anomaly_detector" {
  name        = "aws-sch-cost-anomaly"
  description = "이상 지표 감지 — 매일 03:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 18 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.anomaly_detector.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "monthly_report" {
  name        = "aws-sch-cost-monthly-report"
  description = "월간 리포트 발송 — 매월 28~31일 09:00 KST 실행, Lambda가 마지막 평일 여부 판단 후 발송"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  # 매주 월요일 09:00 KST (= 00:00 UTC) 실행
  # Lambda 내부에서 오늘이 당월 3주차 월요일(15~21일)인지 확인 후 발송 여부 결정
  schedule_expression          = "cron(0 0 ? * MON *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.monthly_report.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

# ---------------------------------------------------------
# SES — mzclinic.cloud 도메인 인증 + DKIM
# ---------------------------------------------------------
resource "aws_sesv2_email_identity" "mzclinic" {
  email_identity = "mzclinic.cloud"

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }

  tags = merge(local.common_tags, { Name = "aws-ses-mzclinic-cloud" })
}

# DKIM 인증용 CNAME 레코드 3개 — Route 53에 자동 추가
resource "aws_route53_record" "ses_dkim" {
  count   = 3
  zone_id = data.aws_route53_zone.mzclinic.zone_id
  name    = "${aws_sesv2_email_identity.mzclinic.dkim_signing_attributes[0].tokens[count.index]}._domainkey.mzclinic.cloud"
  type    = "CNAME"
  ttl     = 300
  records = ["${aws_sesv2_email_identity.mzclinic.dkim_signing_attributes[0].tokens[count.index]}.dkim.${data.aws_region.current.name}.amazonses.com"]
}
