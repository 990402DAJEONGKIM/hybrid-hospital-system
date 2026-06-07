# =============================================================
# Wazuh 일일 보안 보고서 (Bedrock Claude → Slack)
# EventBridge(매일) → Lambda → S3 읽기 → 집계 → Bedrock → Slack
# 리전: ap-south-2 (Hyderabad)
# 네이밍: 프로바이더-리소스-인덱스
# =============================================================



data "aws_region" "current" {}


variable "aws-region-01" {
  default = "ap-south-2"
}

variable "s3-alerts-bucket-01" {
  default = "aws-k2p-storage-01"
}

variable "s3-alerts-prefix-01" {
  description = "vector가 쌓는 alerts 경로 (날짜 폴더 앞부분)"
  default     = "wazuh/alerts"
}

# Bedrock: ap-south-2는 Global CRIS inference profile 필수
# (공식: ap-south-2는 global.anthropic.* inference profile로만 접근)
variable "bedrock-model-id-01" {
  default = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
}


# ── IAM Role ─────────────────────────────────────────────────
resource "aws_iam_role" "aws-wazuh-report-role-01" {
  name = "aws-wazuh-report-role-01"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 최소 권한 정책 (S3 읽기 전용 / Bedrock invoke / SSM 읽기 / 로그)
resource "aws_iam_role_policy" "aws-wazuh-report-policy-01" {
  name = "aws-wazuh-report-policy-01"
  role = aws_iam_role.aws-wazuh-report-role-01.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ReadAlerts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.s3-alerts-bucket-01}",
          "arn:aws:s3:::${var.s3-alerts-bucket-01}/${var.s3-alerts-prefix-01}/*",
          "arn:aws:s3:::${var.s3-alerts-bucket-01}/wazuh/vuln/*"
        ]
      },
      {
        # Global CRIS는 여러 리전으로 라우팅되므로 Resource "*" 또는
        # inference-profile + 하위 foundation-model 모두 필요
        Sid      = "BedrockInvoke"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = ["*"]
      },
      {
        # webhook을 Secrets Manager에서 읽기 (최소권한, 특정 시크릿)
        Sid      = "ReadReportWebhook"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["arn:aws:secretsmanager:${var.aws-region-01}:*:secret:aws-wazuh-slack-report-webhook-*"]
      },
      {
        # 시크릿 복호화용 KMS (sm 키)
        Sid      = "DecryptReportWebhookViaSM"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [data.terraform_remote_state.kms.outputs.secretsmanager_kms_key_arn]
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${data.aws_region.current.region}.amazonaws.com"
          }
        }
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = ["arn:aws:logs:${var.aws-region-01}:*:*"]
      },
            {
        # S3 로그가 aws-kms-s3-01로 암호화돼 있어 읽으려면 Decrypt 필요
        # 최소권한: Decrypt만(쓰기 불가) + 특정 키 ARN + S3 경유로만 제한
        Sid      = "KMSDecryptS3LogsViaS3Only"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [data.terraform_remote_state.kms.outputs.s3_kms_key_arn]
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${data.aws_region.current.region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ── Lambda 패키징 ────────────────────────────────────────────
data "archive_file" "aws-wazuh-report-zip-01" {
  type        = "zip"
  source_file = "${path.module}/lambda/report.py"
  output_path = "${path.module}/lambda/report.zip"
}

# ── Lambda 함수 ──────────────────────────────────────────────
resource "aws_lambda_function" "aws-wazuh-report-fn-01" {
  function_name = "aws-wazuh-report-fn-01"
  role          = aws_iam_role.aws-wazuh-report-role-01.arn
  handler       = "report.handler"
  runtime       = "python3.12"
  timeout       = 300 # 5분: S3 다수 파일 읽기 여유
  memory_size   = 512 # gz 압축해제 버퍼

  filename         = data.archive_file.aws-wazuh-report-zip-01.output_path
  source_code_hash = data.archive_file.aws-wazuh-report-zip-01.output_base64sha256

  environment {
    variables = {
      S3_BUCKET        = var.s3-alerts-bucket-01
      S3_PREFIX        = var.s3-alerts-prefix-01
      BEDROCK_MODEL_ID = var.bedrock-model-id-01
      SLACK_WEBHOOK_SECRET = "aws-wazuh-slack-report-webhook"
      MIN_LEVEL        = "7" # level 7+ 만 보고서 대상
      AWS_REGION_RUNTIME = var.aws-region-01
      VULN_KEY         = "wazuh/vuln/latest.json.gz"
    }
  }
}

# ── EventBridge 스케줄 (매일 KST 자정 = UTC 15:00) ───────────
resource "aws_cloudwatch_event_rule" "aws-wazuh-report-schedule-01" {
  name                = "aws-wazuh-report-schedule-01"
  schedule_expression = "cron(30 23 * * ? *)"  # UTC 23:30 = KST 08:30, 출근 전 보고서
  description         = "Wazuh 일일 보안 보고서 트리거 (매일 KST 08:30)"
}

resource "aws_cloudwatch_event_target" "aws-wazuh-report-target-01" {
  rule      = aws_cloudwatch_event_rule.aws-wazuh-report-schedule-01.name
  target_id = "aws-wazuh-report-target-01"
  arn       = aws_lambda_function.aws-wazuh-report-fn-01.arn
}

resource "aws_lambda_permission" "aws-wazuh-report-perm-01" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws-wazuh-report-fn-01.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.aws-wazuh-report-schedule-01.arn
}
