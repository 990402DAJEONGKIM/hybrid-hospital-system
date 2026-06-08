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



# ECS EC2 Vector → S3 쓰기 + KMS 권한 - 260608 김강환
# Vector가 docker 로그를 S3 ecs/ prefix에 저장하기 위한 최소 권한
resource "aws_iam_role_policy" "ec2_vector_s3" {
  name = "aws-ecs-ec2-vector-s3"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Write"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "arn:aws:s3:::aws-k2p-storage-01/ecs/*"
      },
      {
        Sid    = "KMSEncrypt"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
      }
    ]
  })
}
