data "google_project" "current" {}

data "google_service_account" "billing_reader" {
  account_id = var.billing_reader_sa_account_id
}
