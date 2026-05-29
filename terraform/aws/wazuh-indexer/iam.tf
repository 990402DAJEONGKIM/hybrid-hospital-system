# iam.tf
# Wazuh Indexer 관련 모든 IAM 리소스 모음
# - EC2 인스턴스 역할 (wazuh-indexer 전용)

# ══════════════════════════════════════════
# EC2 IAM Role
# wazuh-indexer EC2 인스턴스에 부여되는 역할
# SSM 접속, CloudWatch 메트릭 전송,
# S3 스냅샷 저장/조회, Ansible 배포에 사용
# ══════════════════════════════════════════
resource "aws_iam_role" "aws-wazuh-indexer-role" {
  name = "aws-wazuh-indexer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "aws-wazuh-indexer-role", Owner = "st2" }
}

# SSM Session Manager 접속 + Ansible 원격 명령 실행을 위한 AWS 관리형 정책
resource "aws_iam_role_policy_attachment" "aws-wazuh-indexer-ssm" {
  role       = aws_iam_role.aws-wazuh-indexer-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 인라인 정책: S3 + KMS
resource "aws_iam_role_policy" "aws-wazuh-indexer-s3" {
  name = "aws-wazuh-indexer-s3-ssm"
  role = aws_iam_role.aws-wazuh-indexer-role.id

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
      # Indexer S3 스냅샷 저장/조회용 (1시간마다 wazuh/snapshots/ 경로에 저장)
      {
        Sid    = "WazuhSnapshotStorage"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*"
        ]
      },
      # aws-k2p-storage-01 버킷 SSE-KMS 암호화/복호화용 KMS 키
      {
        Sid    = "WazuhSnapshotKMS"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
      }
    ]
  })
}

# EC2 인스턴스에 IAM Role을 연결하는 브릿지
resource "aws_iam_instance_profile" "aws-wazuh-indexer-profile" {
  name = "aws-wazuh-indexer-profile"
  role = aws_iam_role.aws-wazuh-indexer-role.name
}