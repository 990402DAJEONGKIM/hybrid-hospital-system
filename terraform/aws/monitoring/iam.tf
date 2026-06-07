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