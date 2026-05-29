# imports.tf
# gcloud로 수동 생성한 리소스를 Terraform state로 가져옵니다.
# 최초 1회 apply 후 이 파일은 삭제해도 됩니다.

import {
  id = "projects/gcp-project-496802/serviceAccounts/gcp-sa-dr-terraform@gcp-project-496802.iam.gserviceaccount.com"
  to = google_service_account.terraform_dr
}

import {
  id = "projects/gcp-project-496802/serviceAccounts/gcp-sa-github-packer@gcp-project-496802.iam.gserviceaccount.com"
  to = google_service_account.github_packer
}

import {
  id = "projects/gcp-project-496802/locations/global/workloadIdentityPools/terraform-cloud-pool"
  to = google_iam_workload_identity_pool.terraform_cloud
}

import {
  id = "projects/gcp-project-496802/locations/global/workloadIdentityPools/terraform-cloud-pool/providers/tfc-provider"
  to = google_iam_workload_identity_pool_provider.terraform_cloud
}

import {
  id = "projects/gcp-project-496802/locations/global/workloadIdentityPools/github-pool"
  to = google_iam_workload_identity_pool.github
}

import {
  id = "projects/gcp-project-496802/locations/global/workloadIdentityPools/github-pool/providers/github-provider"
  to = google_iam_workload_identity_pool_provider.github
}
