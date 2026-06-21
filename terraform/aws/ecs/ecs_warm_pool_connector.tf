# =========================================================
# ecs_warm_pool_connector.tf
#
# Warm Pool(Stopped) 인스턴스가 InService로 전환될 때
# ECS 에이전트가 클러스터에 재연결되지 않는 문제 해결
#
# 흐름:
#   Warm Pool → InService 전환
#     → ASG Lifecycle Hook (Pending:Wait)
#     → EventBridge → Lambda
#     → SSM: sudo systemctl restart ecs
#     → ECS 에이전트 등록 확인
#     → Lifecycle Hook CONTINUE → InService 완료
# =========================================================

# ── Lambda zip 패키징 ─────────────────────────────────────
data "archive_file" "ecs_warm_pool_connector" {
  type        = "zip"
  source_file = "${path.module}/lambda/ecs_warm_pool_connector/lambda_function.py"
  output_path = "${path.module}/lambda/ecs_warm_pool_connector/lambda_function.zip"
}

# ── CloudWatch Logs ───────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs_warm_pool_connector" {
  name              = "/aws/lambda/aws-lambda-ecs-warm-pool-connector"
  retention_in_days = 90
  tags = merge(local.common_tags, { Name = "aws-cwl-ecs-warm-pool-connector" })
}

# ── IAM Role ──────────────────────────────────────────────
resource "aws_iam_role" "ecs_warm_pool_connector" {
  name = "aws-lambda-ecs-warm-pool-connector-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "aws-lambda-ecs-warm-pool-connector-role" })
}

resource "aws_iam_role_policy" "ecs_warm_pool_connector" {
  name = "ecs-warm-pool-connector-policy"
  role = aws_iam_role.ecs_warm_pool_connector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:ListContainerInstances",
          "ecs:DescribeContainerInstances"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["autoscaling:CompleteLifecycleAction"]
        Resource = aws_autoscaling_group.ecs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.ecs_warm_pool_connector.arn}:*"
      }
    ]
  })
}

# ── Lambda ────────────────────────────────────────────────
resource "aws_lambda_function" "ecs_warm_pool_connector" {
  function_name    = "aws-lambda-ecs-warm-pool-connector"
  role             = aws_iam_role.ecs_warm_pool_connector.arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.ecs_warm_pool_connector.output_path
  source_code_hash = data.archive_file.ecs_warm_pool_connector.output_base64sha256
  timeout          = 180

  environment {
    variables = {
      ECS_CLUSTER = aws_ecs_cluster.main.name
    }
  }

  tags = merge(local.common_tags, { Name = "aws-lambda-ecs-warm-pool-connector" })
}

# ── ASG Lifecycle Hook ────────────────────────────────────
resource "aws_autoscaling_lifecycle_hook" "warm_pool_launch" {
  name                   = "ecs-warm-pool-launch-hook"
  autoscaling_group_name = aws_autoscaling_group.ecs.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  heartbeat_timeout      = 300
  default_result         = "ABANDON"
}

# ── EventBridge Rule ──────────────────────────────────────
# Origin=WarmPool, Destination=AutoScalingGroup 조건으로
# 신규 Cold Launch는 제외하고 Warm Pool 전환만 트리거
resource "aws_cloudwatch_event_rule" "warm_pool_launch" {
  name        = "aws-event-warm-pool-ecs-agent-connect"
  description = "Warm Pool 인스턴스 InService 전환 시 ECS 에이전트 재연결"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance-launch Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.ecs.name]
      Origin               = ["WarmPool"]
      Destination          = ["AutoScalingGroup"]
    }
  })

  tags = merge(local.common_tags, { Name = "aws-event-warm-pool-ecs-agent-connect" })
}

resource "aws_cloudwatch_event_target" "warm_pool_launch" {
  rule = aws_cloudwatch_event_rule.warm_pool_launch.name
  arn  = aws_lambda_function.ecs_warm_pool_connector.arn
}

resource "aws_lambda_permission" "eventbridge_warm_pool_connector" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ecs_warm_pool_connector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.warm_pool_launch.arn
}
