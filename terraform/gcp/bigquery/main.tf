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
  attribute_condition = "attribute.aws_role == \"${var.aws_lambda_role_name}\" && attribute.aws_account == \"${var.aws_account_id}\""

  aws {
    account_id = var.aws_account_id
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

# ── Cloud Function: GCP Billing Reader ──────────────────────────────────────

resource "google_storage_bucket" "cf_source" {
  name                        = "${var.project_id}-cf-source"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = local.common_labels
}

data "archive_file" "cf_billing" {
  type        = "zip"
  source_dir  = "${path.module}/cf_billing"
  output_path = "${path.module}/cf_billing.zip"
}

resource "google_storage_bucket_object" "cf_billing" {
  name   = "cf_billing_${data.archive_file.cf_billing.output_md5}.zip"
  bucket = google_storage_bucket.cf_source.name
  source = data.archive_file.cf_billing.output_path
}

resource "google_cloudfunctions2_function" "billing" {
  name     = "gcp-billing-reader"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "get_billing"
    source {
      storage_source {
        bucket = google_storage_bucket.cf_source.name
        object = google_storage_bucket_object.cf_billing.name
      }
    }
  }

  service_config {
    min_instance_count    = 0
    max_instance_count    = 1
    available_memory      = "256M"
    timeout_seconds       = 60
    service_account_email = data.google_service_account.billing_reader.email
    environment_variables = {
      GCP_PROJECT_ID = var.project_id
      BQ_DATASET     = var.dataset_id
      CF_API_KEY     = var.cf_api_key
    }
  }

  labels = local.common_labels
}

resource "google_cloudfunctions2_function_iam_member" "invoker" {
  project        = var.project_id
  location       = var.region
  cloud_function = google_cloudfunctions2_function.billing.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}

# Gen2 Cloud Function은 Cloud Run 위에서 동작하므로 run.invoker도 필요
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.billing.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
