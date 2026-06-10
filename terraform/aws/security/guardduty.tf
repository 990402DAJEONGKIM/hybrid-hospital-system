
# GuardDuty Detector

import {
  to = aws_guardduty_detector.aws-gd
  id = var.guardduty_detector_id
}



resource "aws_guardduty_detector" "aws-gd" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Project = "msp-hospital"
    ISMS    = "2.12.4"
  }
}


# guardduty/ 폴더 사전 생성
resource "aws_s3_object" "guardduty_prefix" {
  bucket       = "aws-k2p-storage-01"
  key          = "guardduty/"
  content_type = "application/x-directory"
}


# GuardDuty → S3 직접 내보내기
resource "aws_guardduty_publishing_destination" "aws-gd-s3" {
  detector_id      = aws_guardduty_detector.aws-gd.id
  destination_type = "S3"
  destination_arn  = "arn:aws:s3:::aws-k2p-storage-01/guardduty/"
  kms_key_arn      = data.terraform_remote_state.kms.outputs.s3_kms_key_arn
  depends_on       = [aws_s3_object.guardduty_prefix]
}


resource "aws_cloudwatch_event_rule" "aws-gd-high" {
  name        = "aws-guardduty-high-severity"
  description = "GuardDuty HIGH 이상 finding 실시간 알람"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "aws-gd-sns" {
  rule = aws_cloudwatch_event_rule.aws-gd-high.name
  arn  = "arn:aws:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:aws-wazuh-cw-alerts-01"
}