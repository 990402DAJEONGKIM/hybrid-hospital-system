# iam.tf

# =========================================================
# IAM — ECS 태스크 실행 역할 + 태스크 역할
# =========================================================

# ─────────────────────────────────────────────────────────
# Task Execution Role
# ECS 에이전트가 사용: ECR 이미지 Pull, CloudWatch 로그 전송,
#                      Secrets Manager 에서 환경변수 주입
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "task_execution" {
  name = "aws-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secrets Manager 읽기 + KMS 복호화 권한 (환경변수 주입용)
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "ecs-task-execution-secrets"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        # 260528 박경수, 시크릿 네이밍 규칙에 맞추면서 주석화 및 수정본 추가
        # Resource = [
        #   data.aws_secretsmanager_secret.db_url.arn,
        #   data.aws_secretsmanager_secret.jwt_secret.arn,
        #   data.aws_secretsmanager_secret.api_key.arn,
        # ]
        Resource = [
            data.tfe_outputs.secrets.values.db_url_patient_secret_arn,
            data.tfe_outputs.secrets.values.db_url_staff_secret_arn,
            data.tfe_outputs.secrets.values.jwt_secret_arn,
            data.tfe_outputs.secrets.values.api_key_secret_arn,
          ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = [data.aws_kms_key.secretsmanager.arn]
      }
    ]
  })
}


# ─────────────────────────────────────────────────────────
# Task Role
# 컨테이너 내부 애플리케이션이 사용: 필요 시 AWS SDK 호출
# 현재는 최소 권한 (필요 시 정책 추가)
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "task" {
  name = "aws-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}


# ─────────────────────────────────────────────────────────
# EC2 Instance Role (ECS 에이전트 + SSM)
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "ec2_instance" {
  name = "aws-ecs-ec2-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ecs" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_instance" {
  name = "aws-ecs-ec2-instance-profile"
  role = aws_iam_role.ec2_instance.name
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
