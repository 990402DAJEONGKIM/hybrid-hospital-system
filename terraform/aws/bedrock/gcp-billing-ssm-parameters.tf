# GCP 빌링 내보내기 BigQuery 테이블명을 SSM에서 관리
# gcp_billing_collector Lambda가 런타임에 읽어 Cloud Function 호출 시 table 파라미터로 전달.
#
# ⚠ 값 변경은 반드시 variables.tf의 gcp_billing_table_name 수정 후 apply로 할 것.
#   AWS 콘솔에서 직접 수정하면 다음 terraform apply 때 변수값으로 덮어써짐.
#   Lambda/CF 재배포는 불필요 — apply 후 다음 Lambda 실행부터 반영됨.

resource "aws_ssm_parameter" "gcp_billing_table_name" {
  name        = "/mzclinic/gcp/billing_table_name"
  description = "GCP billing export BigQuery table name (gcp_billing_export_v1_<billing account id>)"
  type        = "String"
  value       = var.gcp_billing_table_name
  tags        = merge(local.common_tags, { Name = "aws-ssm-gcp-billing-table-name" })
}
