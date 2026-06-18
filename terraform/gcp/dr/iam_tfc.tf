# Terraform Cloud DR workspace service account permissions
# 이 권한은 DR HTTPS 인증서와 Load Balancer 리소스를 IaC로 관리하기 위한 실행 권한이다.

locals {
  dr_terraform_sa_email = "gcp-sa-dr-terraform@gcp-project-496802.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "dr_tfc_certificate_manager_owner" {
  project = var.project_id
  role    = "roles/certificatemanager.owner"
  member  = "serviceAccount:${local.dr_terraform_sa_email}"
}

resource "google_project_iam_member" "dr_tfc_certificate_manager_editor" {
  project = var.project_id
  role    = "roles/certificatemanager.editor"
  member  = "serviceAccount:${local.dr_terraform_sa_email}"
}

resource "google_project_iam_member" "dr_tfc_compute_load_balancer_admin" {
  project = var.project_id
  role    = "roles/compute.loadBalancerAdmin"
  member  = "serviceAccount:${local.dr_terraform_sa_email}"
}
