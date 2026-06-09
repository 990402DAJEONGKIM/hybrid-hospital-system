# ── Keycloak DB 비밀번호 시크릿 ─────────────────────────

resource "aws_secretsmanager_secret" "keycloak_db" {
  name        = "/mzclinic/keycloak/db-password"
  description = "Keycloak DB 비밀번호 (Aurora keycloak 유저) — 90일 자동 로테이션"

  tags = {
    Name    = "mzclinic-keycloak-db-password"
    Project = "mzclinic"
  }
}

resource "aws_secretsmanager_secret_version" "keycloak_db_initial" {
  secret_id = aws_secretsmanager_secret.keycloak_db.id
  secret_string = jsonencode({
    username = "keycloak"
    password = var.keycloak_db_password
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── 로테이션 설정 (90일) ──────────────────────────────────

resource "aws_secretsmanager_secret_rotation" "keycloak_db" {
  secret_id           = aws_secretsmanager_secret.keycloak_db.id
  rotation_lambda_arn = aws_lambda_function.keycloak_db_rotator.arn

  rotation_rules {
    automatically_after_days = 90
  }

  depends_on = [aws_lambda_permission.secrets_manager_invoke]
}

# ── Lambda 함수 ───────────────────────────────────────────

data "archive_file" "keycloak_db_rotator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/keycloak_db_rotator"
  output_path = "${path.module}/lambda/keycloak_db_rotator.zip"
}

resource "aws_lambda_function" "keycloak_db_rotator" {
  function_name    = "mzclinic-keycloak-db-rotator"
  role             = aws_iam_role.keycloak_db_rotator.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.keycloak_db_rotator.output_path
  source_code_hash = data.archive_file.keycloak_db_rotator.output_base64sha256
  timeout          = 300

  vpc_config {
    subnet_ids         = [
      "subnet-043fe497537a7b41b",  # aws-app-sub-2b
      "subnet-03a995e88f620566e",  # aws-app-sub-2a
    ]
    security_group_ids = ["sg-0c5f737e7de383854"]  # aws-sg-lambda-rotation
  }

  environment {
    variables = {
      MASTER_SECRET_ARN    = "arn:aws:secretsmanager:${var.aws_region}:476293896981:secret:rds!cluster-1073d242-a1f9-49fa-8855-054d05d6af5b"
      AURORA_HOST          = var.aurora_endpoint
      KEYCLOAK_INSTANCE_ID = aws_instance.aws-monitoring-01.id
      # AWS_REGION는 Lambda 예약 환경변수 — 자동 주입됨
    }
  }

  tags = {
    Name    = "mzclinic-keycloak-db-rotator"
    Project = "mzclinic"
  }
}

# Secrets Manager가 Lambda 호출할 수 있도록 권한 부여
resource "aws_lambda_permission" "secrets_manager_invoke" {
  statement_id  = "SecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.keycloak_db_rotator.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.keycloak_db.arn
}
