# iam.tf(역할)
# Wazuh 관련 모든 IAM 리소스 모음
# - EC2 인스턴스 역할 (wazuh-01, wazuh-02 공유)
# - Lambda 역할 2개 (slack-notify, wodle-failover)

# ══════════════════════════════════════════
# EC2 IAM Role
# wazuh-01, wazuh-02 EC2 인스턴스에 부여되는 역할
# SSM 접속, CloudWatch 메트릭 전송, S3/CloudWatch Logs 접근에 사용
# ══════════════════════════════════════════
resource "aws_iam_role" "aws-wazuh-ssm-role" {
  name = "aws-wazuh-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "aws-wazuh-ssm-role", Owner = "st2" }
}



# SSM Session Manager 접속 + Ansible 원격 명령 실행을 위한 AWS 관리형 정책
resource "aws_iam_role_policy_attachment" "aws-wazuh-ssm" {
  role       = aws_iam_role.aws-wazuh-ssm-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 인라인 정책: S3 + KMS + CloudWatch Logs
resource "aws_iam_role_policy" "aws-wazuh-s3-policy" {
  name = "aws-wazuh-s3-policy"
  role = aws_iam_role.aws-wazuh-ssm-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Ansible 배포 시 wazuh-install-files.tar 업/다운로드용 S3 버킷
      {
        Sid    = "AnsibleSSM"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::wazuh-ansible-ssm",
          "arn:aws:s3:::wazuh-ansible-ssm/*"
        ]
      },
      # Vector alerts, wodle DB 백업, Indexer 스냅샷 저장용 S3 버킷
      {
        Sid    = "WazuhLogStorage"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*",
          "arn:aws:s3:::aws-k2p-alb-01",
          "arn:aws:s3:::aws-k2p-alb-01/*"
        ]
      },
      # aws-k2p-storage-01 버킷 SSE-KMS 암호화/복호화용 KMS 키
      {
        Sid    = "KMSForS3"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
      },
      # Wazuh wodle이 CloudWatch Logs에서 로그 수집 시 필요한 권한
      # 대상: RDS Aurora PostgreSQL 감사 로그, ECS 환자/의료진 포털 로그
      {
        Sid    = "CloudWatchLogsRead"
        Effect = "Allow"
        Action = [
          "logs:GetLogEvents",
          "logs:DescribeLogStreams",
          
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/rds/cluster/aws-aurora-01/postgresql",
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/rds/cluster/aws-aurora-01/postgresql:*",
          "arn:aws:logs:${var.aws_region}:*:log-group:/ecs/patient",
          "arn:aws:logs:${var.aws_region}:*:log-group:/ecs/patient:*",
          "arn:aws:logs:${var.aws_region}:*:log-group:/ecs/staff",
          "arn:aws:logs:${var.aws_region}:*:log-group:/ecs/staff:*",
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/vendedlogs/vpn/aws-vpn-01",
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/vendedlogs/vpn/aws-vpn-01:*",
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/vendedlogs/vpn/aws-vpn-gcp",
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/vendedlogs/vpn/aws-vpn-gcp:*",
          "arn:aws:logs:${var.aws_region}:*:log-group:aws-waf-logs-patient-alb",
          "arn:aws:logs:${var.aws_region}:*:log-group:aws-waf-logs-patient-alb:*",
          "arn:aws:logs:${var.aws_region}:*:log-group:aws-waf-logs-staff-alb",
          "arn:aws:logs:${var.aws_region}:*:log-group:aws-waf-logs-staff-alb:*",
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/rds/proxy/aws-rds-proxy-01",
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/rds/proxy/aws-rds-proxy-01:*",
        ]
      },
      # aws-wazuh-s3 인라인 정책에 추가
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      # DescribeLogGroups는 AWS API 구조상 Resource * 필수
      {
        Sid    = "CloudWatchLogsDescribe"
        Effect = "Allow"
        Action = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      # VPC Flow Log wodle 내부에서 ec2:DescribeFlowLogs 호출
      {
        Sid    = "EC2DescribeFlowLogs"
        Effect = "Allow"
        Action = ["ec2:DescribeFlowLogs"]
        Resource = "*"
      },
            # 취약점 cron이 인덱서 비번 읽기 (Secrets Manager)
      {
        Sid    = "ReadIndexerSecret"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:aws-wazuh-indexer-credentials-*",
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:aws-wazuh-slack-alarm-webhook-*",
          # [2026-06-10 박경수] Wazuh Dashboard Keycloak OIDC 및 세션 cookie secret 읽기 권한 추가
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:aws-wazuh-openid-client-secret-*",
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:aws-wazuh-dashboard-cookie-password-*"
        ]
      },
      # 위 시크릿 복호화용 KMS (sm 키, Secrets Manager 경유만)
      {
        Sid    = "DecryptIndexerSecretViaSM"
        Effect = "Allow"
        Action = ["kms:Decrypt"]
        Resource = data.terraform_remote_state.kms.outputs.secretsmanager_kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# EC2 인스턴스에 IAM Role을 연결하는 브릿지
# wazuh-01에서 생성, wazuh-02는 data로 참조만 함
resource "aws_iam_instance_profile" "aws-wazuh-profile" {
  name = "aws-wazuh-instance-profile"
  role = aws_iam_role.aws-wazuh-ssm-role.name
}


# ══════════════════════════════════════════
# Lambda IAM Role - Slack 알림
# CloudWatch 알람 → SNS → Lambda → Slack 구조에서
# Lambda가 CloudWatch Logs에 실행 로그를 남기기 위한 역할
# ══════════════════════════════════════════
resource "aws_iam_role" "aws-wazuh-lambda-slack-notify-role" {
  name = "aws-wazuh-lambda-slack-notify-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Lambda 기본 실행 권한 (CloudWatch Logs 쓰기)
resource "aws_iam_role_policy_attachment" "aws-wazuh-lambda-basic" {
  role       = aws_iam_role.aws-wazuh-lambda-slack-notify-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "aws-wazuh-lambda-slack-notify-secrets" {
  name = "aws-wazuh-lambda-slack-notify-secrets"
  role = aws_iam_role.aws-wazuh-lambda-slack-notify-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # alarm webhook 시크릿 1개만 읽기 (최소권한)
        Sid      = "ReadAlarmWebhook"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:aws-wazuh-slack-alarm-webhook-*"
      },
      {
        # 시크릿 복호화용 KMS (sm 키, Secrets Manager 경유만)
        Sid      = "DecryptViaSM"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.terraform_remote_state.kms.outputs.secretsmanager_kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}




# ══════════════════════════════════════════
# Lambda IAM Role - Agent 정리
# ecs-ec2 그룹 disconnected Agent 주기적 삭제
# Secrets Manager 읽기 권한만 부여 (최소 권한 원칙)
# ══════════════════════════════════════════
resource "aws_iam_role" "aws-wazuh-lambda-agent-cleanup-role" {
  name = "aws-wazuh-lambda-agent-cleanup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Lambda 기본 실행 권한 (CloudWatch Logs 쓰기 - 증적용)
resource "aws_iam_role_policy_attachment" "aws-wazuh-lambda-agent-cleanup-basic" {
  role       = aws_iam_role.aws-wazuh-lambda-agent-cleanup-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Secrets Manager 읽기 (Wazuh API 비밀번호 조회용)
resource "aws_iam_role_policy" "aws-wazuh-lambda-agent-cleanup-policy" {
  name = "aws-wazuh-lambda-agent-cleanup-policy"
  role = aws_iam_role.aws-wazuh-lambda-agent-cleanup-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 수정: wazuh/* → aws-wazuh-api-password (실제 시크릿 이름과 안 맞아 깨져있었음)
        Sid      = "SecretsManagerRead"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:aws-wazuh-api-password-*"
      },
      {
        # 추가: KMS 복호화 (이게 없어서 이름 고쳐도 또 막혔을 것)
        Sid      = "DecryptApiSecretViaSM"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.terraform_remote_state.kms.outputs.secretsmanager_kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "aws-wazuh-lambda-recovery-role" {
  name = "aws-wazuh-lambda-recovery-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws-wazuh-lambda-recovery-basic" {
  role       = aws_iam_role.aws-wazuh-lambda-recovery-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "aws-wazuh-lambda-recovery-policy" {
  name = "aws-wazuh-lambda-recovery-policy"
  role = aws_iam_role.aws-wazuh-lambda-recovery-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Recovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:TerminateInstances",
          "ec2:RunInstances",
          "ec2:CreateTags"
        ]
        Resource = "*"
      },
      {
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
        Sid    = "IAMPassRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = aws_iam_role.aws-wazuh-ssm-role.arn
      }
    ]
  })
}