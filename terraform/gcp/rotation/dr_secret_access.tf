# terraform/gcp/rotation/dr_secret_access.tf
# rotation SA에 DR 앱 시크릿 접근 권한 부여
# gcp-dr-jwt-secret, gcp-dr-api-key rotation에 필요

resource "google_secret_manager_secret_iam_member" "rotation_dr_jwt" {
  secret_id = "gcp-dr-jwt-secret"
  role      = "roles/secretmanager.secretVersionManager"
  member    = "serviceAccount:${google_service_account.rotation_fn.email}"
}

resource "google_secret_manager_secret_iam_member" "rotation_dr_api_key" {
  secret_id = "gcp-dr-api-key"
  role      = "roles/secretmanager.secretVersionManager"
  member    = "serviceAccount:${google_service_account.rotation_fn.email}"
}
