
# GuardDuty Detector

import {
  to = aws_guardduty_detector.aws-gd
  id = "692bc5874baa41429fc7396c82c862c6"
}

resource "aws_guardduty_detector" "aws-gd" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Project = "msp-hospital"
    ISMS    = "2.12.4"
  }
}



# GuardDuty → S3 직접 내보내기
resource "aws_guardduty_publishing_destination" "aws-gd-s3" {
  detector_id     = aws_guardduty_detector.aws-gd.id
  destination_arn = "arn:aws:s3:::aws-k2p-storage-01"
  kms_key_arn     =  data.terraform_remote_state.kms.outputs.s3_kms_key_arn


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
  arn  = "arn:aws:sns:ap-south-2:476293896981:aws-wazuh-cw-alerts-01"
}