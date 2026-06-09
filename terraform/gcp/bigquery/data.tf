data "google_project" "current" {}

data "google_service_account" "billing_reader" {
  account_id = var.billing_reader_sa_account_id
}

data "terraform_remote_state" "bedrock" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-Bedrock" }
  }
}
