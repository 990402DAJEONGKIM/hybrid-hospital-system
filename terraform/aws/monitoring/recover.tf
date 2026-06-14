# ─────────────────────────────────────────────────────────
# 모니터링 복구 Lambda - 추가 260614 김강환
# 인덱서(aws-wazuh-lambda-indexer-recovery)와 동일한 패턴
# ─────────────────────────────────────────────────────────
data "archive_file" "aws-monitoring-lambda-recovery" {
  type        = "zip"
  source_file = "${path.module}/lambda/monitoring_recovery.py"
  output_path = "${path.module}/lambda/monitoring_recovery.zip"
}

resource "aws_lambda_function" "aws-monitoring-lambda-recovery" {
  function_name    = "aws-monitoring-lambda-recovery"
  filename         = data.archive_file.aws-monitoring-lambda-recovery.output_path
  source_code_hash = data.archive_file.aws-monitoring-lambda-recovery.output_base64sha256
  handler          = "monitoring_recovery.handler"
  runtime          = "python3.12"
  timeout          = 900
  role             = aws_iam_role.aws-monitoring-lambda-recovery-role.arn

  environment {
    variables = {
      SUBNET_ID        = data.aws_subnet.aws-app-sub-2b.id
      SG_ID            = aws_security_group.aws-monitoring-sg.id
      INSTANCE_PROFILE = aws_iam_instance_profile.aws-monitoring-profile.name
      INSTANCE_TYPE    = "t3.medium"
      PRIVATE_IP       = var.monitoring_private_ip
      INSTANCE_NAME    = "aws-monitoring-01"
      AMI_NAME_PREFIX  = "aws-monitoring-"
      ACCOUNT_ID       = data.aws_caller_identity.current.account_id
    }
  }
  tags = { Name = "aws-monitoring-lambda-recovery" }
}