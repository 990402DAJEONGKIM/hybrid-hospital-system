# ── Lambda zip 패키징 ─────────────────────────────────────
data "archive_file" "ecs_redeployer" {
  type        = "zip"
  source_file = "${path.module}/lambda/ecs_redeployer/lambda_ecs_redeployer.py"
  output_path = "${path.module}/lambda/ecs_redeployer/lambda_ecs_redeployer.zip"
}

# ── CloudWatch Logs ───────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs_redeployer" {
  name              = "/aws/lambda/aws-lambda-ecs-redeployer"
  retention_in_days = 90
  tags = merge(local.common_tags, { Name = "aws-cwl-ecs-redeployer" })
}

# ── IAM Role ──────────────────────────────────────────────
resource "aws_iam_role" "ecs_redeployer" {
  name = "aws-lambda-ecs-redeployer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "aws-lambda-ecs-redeployer-role" })
}

resource "aws_iam_role_policy" "ecs_redeployer" {
  name = "ecs-redeployer-policy"
  role = aws_iam_role.ecs_redeployer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ecs:UpdateService"]
        Resource = [
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/aws-ecs-cluster-01/patient-service",
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/aws-ecs-cluster-01/staff-service",
        ]
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.ecs_redeployer.arn}:*"
      }
    ]
  })
}

# ── Lambda ────────────────────────────────────────────────
resource "aws_lambda_function" "ecs_redeployer" {
  function_name    = "aws-lambda-ecs-redeployer"
  role             = aws_iam_role.ecs_redeployer.arn
  runtime          = "python3.12"
  handler          = "lambda_ecs_redeployer.lambda_handler"
  filename         = data.archive_file.ecs_redeployer.output_path
  source_code_hash = data.archive_file.ecs_redeployer.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      ECS_CLUSTER        = "aws-ecs-cluster-01"
      PATIENT_SECRET_ARN = data.tfe_outputs.secrets.values.db_url_patient_secret_arn
      PATIENT_SERVICE    = "patient-service"
      READER_SECRET_ARN  = data.tfe_outputs.secrets.values.db_read_url_patient_secret_arn
      HOSPITAL_SERVICE   = "hospital-service"
    }
  }

  tags = merge(local.common_tags, { Name = "aws-lambda-ecs-redeployer" })
}

# ── EventBridge ───────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "secret_rotation_complete" {
  name        = "aws-event-secret-rotation-ecs-redeploy"
  description = "Secrets Manager 로테이션 완료 시 ECS 재배포"

  event_pattern = jsonencode({
    source      = ["aws.secretsmanager"]
    detail-type = ["Rotation Succeeded"]
    resources = [
      data.tfe_outputs.secrets.values.db_url_patient_secret_arn,
      data.tfe_outputs.secrets.values.db_read_url_patient_secret_arn,
    ]
  })

  tags = merge(local.common_tags, { Name = "aws-event-secret-rotation-ecs-redeploy" })
}

resource "aws_cloudwatch_event_target" "ecs_redeployer" {
  rule = aws_cloudwatch_event_rule.secret_rotation_complete.name
  arn  = aws_lambda_function.ecs_redeployer.arn
}

resource "aws_lambda_permission" "eventbridge_ecs_redeployer" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ecs_redeployer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.secret_rotation_complete.arn
}
