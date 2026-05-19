variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-south-2"
}

variable "aws_account_id" {
  description = "AWS 계정 ID"
  type        = string
}

variable "image_tag_mutability" {
  description = "이미지 태그 변경 가능 여부 (MUTABLE / IMMUTABLE)"
  type        = string
  default     = "IMMUTABLE"
}

variable "image_retention_count" {
  description = "보관할 이미지 최대 개수 (Lifecycle Policy)"
  type        = number
  default     = 10
}
