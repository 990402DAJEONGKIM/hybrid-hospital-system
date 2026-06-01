output "guardduty_detector_id" {
  description = "GuardDuty detector ID — KMS/S3 policy aws:SourceArn 참조용"
  value       = aws_guardduty_detector.aws-gd.id
}