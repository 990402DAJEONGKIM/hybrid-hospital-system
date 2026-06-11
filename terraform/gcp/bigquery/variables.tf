variable "project_id" {
  description = "GCP 프로젝트 ID"
  type        = string
}

variable "region" {
  description = "GCP 리전"
  type        = string
  default     = "asia-northeast3"
}

variable "dataset_id" {
  description = "BigQuery 데이터셋 ID"
  type        = string
  default     = "billing_export"
}

variable "aws_lambda_role_name" {
  description = "GCP에 접근할 AWS Lambda IAM 역할 이름"
  type        = string
  default     = "aws-cost-lambda-role"
}

variable "billing_reader_sa_account_id" {
  description = "BigQuery 조회 서비스 계정 account_id (이메일의 @ 앞부분)"
  type        = string
  default     = "billing-reader-sa"
}

variable "aws_account_id" {
  description = "AWS 계정 ID (WIF 프로바이더 및 attribute_condition에 사용)"
  type        = string
}

variable "cf_api_key" {
  description = "Cloud Function 호출 인증키 (AWS Lambda에서 X-Api-Key 헤더로 전달)"
  type        = string
  sensitive   = true
}

variable "billing_export_table" {
  description = "GCP 빌링 내보내기가 생성한 BigQuery 테이블명 (gcp_billing_export_v1_<빌링계정ID> 형식)"
  type        = string
  default     = "gcp_billing_export_v1_011034_3337E0_C3B9BF"
}
