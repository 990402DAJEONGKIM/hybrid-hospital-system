# variables.tf
variable "aws_region" {
  description = "AWS 배포 리전"
  type        = string
}

variable "guardduty_detector_id" {
  description = "기존 GuardDuty Detector ID (import용)"
  type        = string
}