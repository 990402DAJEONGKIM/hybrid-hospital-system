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
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:aws-grafana-admin-password*",
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:aws-wazuh-slack-alarm-webhook*",


          # [2026-06-10 박경수] Grafana / Monitoring Portal Keycloak SSO secret 런타임 조회
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:aws-grafana-openid-client-secret*",
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:aws-monitoring-portal-openid-client-secret*",
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:aws-monitoring-portal-cookie-secret*",

          # [2026-06-10 박경수] Keycloak wazuh client secret 재동기화용 런타임 조회 권한
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:aws-wazuh-openid-client-secret*"
          
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
        # EC2 재구축 + EBS 분리/부착 - 수정 260614 김강환
        Sid    = "EC2Recovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeImages",
          "ec2:DescribeVolumes",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:CreateTags",
          "ec2:AttachVolume",
          "ec2:DetachVolume"
        ]
        Resource = "*"
      },
      {
        # grafana/ prefix 읽기 권한
        # user_data 실행 시 초기화 스크립트 + 대시보드 JSON S3에서 가져오기 - 추가 260612 김강환
        Sid    = "GrafanaS3Read"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket","s3:PutObject"]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/monitoring/*"
        ]
      },

      {
        Sid    = "KMSDecryptSSM"
        Effect = "Allow"
        Action = ["kms:Decrypt"]
        Resource = "arn:aws:kms:ap-south-2:476293896981:key/852d441e-9d83-4a2b-9c95-c7a903fe5ee3"
      },     
      {
        # S3 grafana/ prefix KMS 복호화 권한 - 추가 260612 김강환
        Sid    = "S3KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
      },

      {
        # SSM Parameter Store 읽기 - user_data 런타임 변수 조회 - 추가 260612 김강환
        Sid    = "SSMParamRead"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/mzclinic/keycloak/*",
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/wazuh/*"
        ]
      },
      # monitoring/iam.tf
      # CloudWatch 읽기 + 커스텀 메트릭 쓰기 - 수정 260614 김강환
      # PutMetricData 추가: grafana-health.sh, prometheus-health.sh 크론 스크립트용
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetInsightRuleReport",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
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
        Sid    = "CostChatSSMParamRead"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:476293896981:parameter/mzclinic/cost/chat/*"
      },
      {
        Sid    = "KeycloakS3ScriptRead"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = "arn:aws:s3:::aws-k2p-storage-01/monitoring/*"
      },
      {
        Sid    = "KeycloakS3KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = "arn:aws:kms:ap-south-2:476293896981:key/e2b6e04e-e603-4388-ae54-c397fb72dee2"
      },
    ]
  })
}
# #260609 박경수 end



# 모니터링 복구 Lambda IAM - 추가 260614 김강환
# 인덱서(aws-wazuh-indexer-recovery-role)와 동일한 패턴
resource "aws_iam_role" "aws-monitoring-lambda-recovery-role" {
  name = "aws-monitoring-lambda-recovery-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "aws-monitoring-lambda-recovery-role" }
}

resource "aws_iam_role_policy_attachment" "aws-monitoring-lambda-recovery-basic" {
  role       = aws_iam_role.aws-monitoring-lambda-recovery-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "aws-monitoring-lambda-recovery-policy" {
  name = "aws-monitoring-lambda-recovery-policy"
  role = aws_iam_role.aws-monitoring-lambda-recovery-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # EC2 재구축
        Sid    = "EC2Recovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeImages",
          "ec2:DescribeVolumes",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:CreateTags",
          "ec2:AttachVolume",
          "ec2:DetachVolume"
        ]
        Resource = "*"
      },
      {
        # SSM으로 서비스 재시작
        Sid    = "SSMRecovery"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:DescribeInstanceInformation"
        ]
        Resource = "*"
      },
      {
        # 새 인스턴스에 모니터링 인스턴스 프로파일 부여
        Sid      = "PassMonitoringRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${aws_iam_instance_profile.aws-monitoring-profile.role}"
      },
      #2026-06-21 김강환 추가
      {
        Sid    = "KMSForEC2"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = data.terraform_remote_state.kms.outputs.ebs_kms_key_arn
      },
      {
        Sid    = "KMSCreateGrantForEC2"
        Effect = "Allow"
        Action = ["kms:CreateGrant"]
        Resource = data.terraform_remote_state.kms.outputs.ebs_kms_key_arn
        Condition = {
          Bool = { "kms:GrantIsForAWSResource" = "true" }
        }
      }


    ]
  })
}