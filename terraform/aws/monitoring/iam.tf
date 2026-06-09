# monitoring/iam.tf
# EC2 IAM Role — SSM 접속 전용
# CloudWatch 읽기는 Grafana Data Source에서 직접 처리
# ISMS-P 2.5.3 최소 권한 원칙
resource "aws_iam_role" "aws-monitoring-role" {
  name = "aws-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "aws-monitoring-role" }
}

# SSM Session Manager 접속
resource "aws_iam_role_policy_attachment" "aws-monitoring-ssm" {
  role       = aws_iam_role.aws-monitoring-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch 읽기 — Grafana CloudWatch Data Source용
resource "aws_iam_role_policy" "aws-monitoring-cloudwatch" {
  name = "aws-monitoring-cloudwatch"
  role = aws_iam_role.aws-monitoring-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Grafana CloudWatch Data Source가 메트릭 읽기에 필요한 최소 권한
        # 공식문서: https://grafana.com/docs/grafana/latest/datasources/aws-cloudwatch/
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetInsightRuleReport"
        ]
        Resource = "*"
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:aws-grafana-admin-password*",
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:aws-wazuh-slack-alarm-webhook*"
        ]
      },
      {
        # Secrets Manager KMS 복호화 권한
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = data.terraform_remote_state.kms.outputs.secretsmanager_kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${data.aws_region.current.region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "ResourceRead"
        Effect = "Allow"
        Action = [
          "ec2:DescribeTags",
          "ec2:DescribeInstances",
          "ec2:DescribeRegions",
          "ec2:DescribeAvailabilityZones",
          "tag:GetResources"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "aws-monitoring-profile" {
  name = "aws-monitoring-instance-profile"
  role = aws_iam_role.aws-monitoring-role.name
}
# #260609 박경수 — Keycloak DB rotator Lambda IAM role
resource "aws_iam_role" "keycloak_db_rotator" {
  name = "mzclinic-keycloak-db-rotator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "mzclinic-keycloak-db-rotator-role" }
}

resource "aws_iam_role_policy_attachment" "keycloak_rotator_vpc" {
  role       = aws_iam_role.keycloak_db_rotator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "keycloak_db_rotator" {
  name = "mzclinic-keycloak-db-rotator-policy"
  role = aws_iam_role.keycloak_db_rotator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KeycloakSecretRotation"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
          "secretsmanager:DescribeSecret",
        ]
        Resource = aws_secretsmanager_secret.keycloak_db.arn
      },
      {
        Sid      = "MasterSecretRead"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:476293896981:secret:rds!cluster-1073d242-a1f9-49fa-8855-054d05d6af5b"
      },
      {
        Sid    = "SSMRunCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:476293896981:instance/${aws_instance.aws-monitoring-01.id}",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        ]
      },
      {
        Sid    = "SSMParameterRead"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:476293896981:parameter/mzclinic/keycloak/*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

# EC2 인스턴스 역할에 Keycloak 시크릿 읽기 추가
# (설치 스크립트 + 재시작 시 Secrets Manager 조회)
resource "aws_iam_role_policy" "monitoring_keycloak_secrets" {
  name = "mzclinic-monitoring-keycloak-secrets"
  role = aws_iam_role.aws-monitoring-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KeycloakSecretsRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.keycloak_db.arn
      },
      {
        Sid    = "KeycloakSSMParamRead"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:476293896981:parameter/mzclinic/keycloak/*"
      },
      {
        Sid    = "KeycloakS3ScriptRead"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = "arn:aws:s3:::aws-k2p-storage-01/monitoring/*"
      },
    ]
  })
}
# #260609 박경수 end
