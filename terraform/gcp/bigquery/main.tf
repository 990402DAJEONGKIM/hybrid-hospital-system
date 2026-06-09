# ── BigQuery 데이터셋 ────────────────────────────────────────────────────────

resource "google_bigquery_dataset" "billing" {
  dataset_id                  = var.dataset_id
  location                    = var.region
  description                 = "GCP 클라우드 빌링 내보내기 데이터셋"
  delete_contents_on_destroy  = false

  labels = local.common_labels
}

# ── WIF 풀 (AWS Lambda → GCP) ────────────────────────────────────────────────

resource "google_iam_workload_identity_pool" "aws_lambda" {
  workload_identity_pool_id = "aws-lambda-pool"
  display_name              = "AWS Lambda Pool"
  description               = "AWS Lambda가 GCP 리소스에 접근하기 위한 WIF 풀"

  labels = local.common_labels
}

resource "google_iam_workload_identity_pool_provider" "aws_lambda" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.aws_lambda.workload_identity_pool_id
  workload_identity_pool_provider_id = "aws-lambda-provider"
  display_name                       = "AWS Lambda Provider"
  description                        = "AWS Lambda 역할 기반 자격증명 프로바이더"

  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.aws_role" = "assertion.arn.extract('assumed-role/{role}/')"
    "attribute.aws_account" = "assertion.account"
  }

  # aws-cost-lambda-role을 assume한 세션만 허용
  attribute_condition = "attribute.aws_role == \"${var.aws_lambda_role_name}\" && attribute.aws_account == \"${data.terraform_remote_state.bedrock.outputs.aws_account_id}\""

  aws {
    account_id = data.terraform_remote_state.bedrock.outputs.aws_account_id
  }
}

# ── 서비스 계정 IAM: WIF 풀 → billing-reader-sa 위장(impersonate) ────────────

resource "google_service_account_iam_member" "wif_lambda_impersonate" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${data.google_service_account.billing_reader.email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.aws_lambda.name}/attribute.aws_role/${var.aws_lambda_role_name}"
}

# ── BigQuery 권한: billing-reader-sa ────────────────────────────────────────

resource "google_bigquery_dataset_iam_member" "billing_reader_viewer" {
  dataset_id = google_bigquery_dataset.billing.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${data.google_service_account.billing_reader.email}"
}

resource "google_project_iam_member" "billing_reader_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${data.google_service_account.billing_reader.email}"
}
