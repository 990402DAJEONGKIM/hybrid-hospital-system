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

# CloudWatch Agent가 메트릭/로그를 CloudWatch로 전송하기 위한 AWS 관리형 정책
resource "aws_iam_role_policy_attachment" "aws-wazuh-cloudwatch" {
  role       = aws_iam_role.aws-wazuh-ssm-role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# SSM Session Manager 접속 + Ansible 원격 명령 실행을 위한 AWS 관리형 정책
resource "aws_iam_role_policy_attachment" "aws-wazuh-ssm" {
  role       = aws_iam_role.aws-wazuh-ssm-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 인라인 정책: S3 + KMS + CloudWatch Logs
resource "aws_iam_role_policy" "aws-wazuh-s3" {
  name = "aws-wazuh-s3"
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
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*"
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
          "logs:DescribeLogGroups"
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/rds/cluster/aws-aurora-01/postgresql",
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/rds/cluster/aws-aurora-01/postgresql:*",
          "arn:aws:logs:${var.aws_region}:*:log-group:/ecs/patient",
          "arn:aws:logs:${var.aws_region}:*:log-group:/ecs/patient:*",
          "arn:aws:logs:${var.aws_region}:*:log-group:/ecs/staff",
          "arn:aws:logs:${var.aws_region}:*:log-group:/ecs/staff:*"
        ]
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
resource "aws_iam_role" "aws-wazuh-slack-notify-role" {
  name = "aws-wazuh-slack-notify-role"

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
  role       = aws_iam_role.aws-wazuh-slack-notify-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}


# ══════════════════════════════════════════
# Lambda IAM Role - wodle HA Failover
# wazuh-01 장애 시 wazuh-02의 wodle을 자동으로 켜고 끄는 Lambda
# CloudWatch 알람 확인, SSM 명령 실행, Parameter Store 상태 저장에 사용
# ══════════════════════════════════════════
resource "aws_iam_role" "aws-wazuh-wodle-failover-role" {
  name = "aws-wazuh-wodle-failover-role"

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
resource "aws_iam_role_policy_attachment" "aws-wazuh-wodle-failover-basic" {
  role       = aws_iam_role.aws-wazuh-wodle-failover-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# 인라인 정책: CloudWatch 알람 조회 + SSM 명령 실행 + Parameter Store 읽기/쓰기
resource "aws_iam_role_policy" "aws-wazuh-wodle-failover-policy" {
  name = "aws-wazuh-wodle-failover-policy"
  role = aws_iam_role.aws-wazuh-wodle-failover-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # wazuh-01 EC2/Manager 상태 알람 확인용
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = ["cloudwatch:DescribeAlarms"]
        Resource = "*"
      },
      # wazuh-02에 SSM 명령 전송 (wodle disabled 설정 변경 + wazuh-manager 재시작)
      {
        Sid    = "SSMSendCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation"
        ]
        Resource = [
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
          data.terraform_remote_state.wazuh2.outputs.wazuh_instance_arn
        ]
      },
      # 현재 active 서버 상태를 Parameter Store에 저장/조회
      # 키: /wazuh/wodle-active-server (값: wazuh-01 또는 wazuh-02)
      {
        Sid    = "SSMParameter"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/wazuh/*"
      }
    ]
  })
}