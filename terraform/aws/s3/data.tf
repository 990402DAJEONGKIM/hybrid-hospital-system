data "aws_kms_key" "s3" {
  key_id = "alias/aws-kms-s3-01"
}

# 현재 실행 중인 AWS 계정 ID 동적 참조
data "aws_caller_identity" "current" {}

# 현재 배포 중인 AWS 리전 동적 참조
data "aws_region" "current" {}


# TC-aws-KMS 워크스페이스 output에서 s3_kms_key_arn 참조
# DenyGuardDutyWrongKMSKey Statement의 KMS ARN 값으로 사용
data "terraform_remote_state" "kms" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-KMS"
    }
  }
}
# TC-aws-security output에서 guardduty_detector_id 동적 참조
data "terraform_remote_state" "security" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-security"
    }
  }
}


output "alb_logs_bucket_name" {
  description = "ALB 액세스 로그 버킷 이름 (TC-aws-ALB에서 참조)"
  value       = aws_s3_bucket.aws-alb-logs-01.bucket
}