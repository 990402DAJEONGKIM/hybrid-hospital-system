# 추가 260610 김강환
data "archive_file" "aws-wazuh-indexer-recovery-zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/recovery.py"
  output_path = "${path.module}/lambda/recovery.zip"
}

resource "aws_lambda_function" "aws-wazuh-indexer-recovery" {
  function_name    = "aws-wazuh-lambda-indexer-recovery"
  filename         = data.archive_file.aws-wazuh-indexer-recovery-zip.output_path
  source_code_hash = data.archive_file.aws-wazuh-indexer-recovery-zip.output_base64sha256
  handler          = "recovery.handler"
  runtime          = "python3.12"
  timeout          = 900   # 재구축 waiter(종료+기동+SSM) 대비 최대 15분
  role             = aws_iam_role.aws-wazuh-indexer-recovery-role.arn

  environment {
    variables = {
      # 전부 비민감 인프라 식별자 — 시크릿 없음 (ISMS-P 하드코딩 금지 준수)
      SUBNET_ID        = data.aws_subnet.aws-app-sub-2c.id
      SG_ID            = aws_security_group.aws-wazuh-indexer-sg.id
      INSTANCE_PROFILE = aws_iam_instance_profile.aws-wazuh-indexer-profile.name
      INSTANCE_TYPE    = "t3.xlarge"
      PRIVATE_IP       = var.indexer_private_ip
      INSTANCE_NAME    = "aws-wazuh-indexer"
      DATA_VOLUME_NAME = "aws-wazuh-indexer-data-01"
      DATA_DEVICE      = "/dev/sdf"
      MOUNT_POINT      = "/mnt/wazuh-indexer-data"
      AMI_NAME_PREFIX  = "aws-wazuh-indexer-"
      ACCOUNT_ID       = data.aws_caller_identity.current.account_id
    }
  }
  tags = { Name = "aws-wazuh-lambda-indexer-recovery", Owner = "st2" }
}