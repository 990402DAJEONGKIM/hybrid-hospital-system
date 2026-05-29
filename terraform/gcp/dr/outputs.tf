output "dr_lb_ip" {
  description = "GCP DR 예약 서비스 외부 LB IP"
  value       = google_compute_global_address.dr_lb.address
}

output "dr_mig_name" {
  description = "DR 앱 Managed Instance Group 이름"
  value       = google_compute_instance_group_manager.dr_app.name
}

output "artifact_bucket" {
  description = "DR 앱 아티팩트 버킷"
  value       = google_storage_bucket.artifact.name
}

output "monitor_script_gcs_uri" {
  description = "프록시 VM 모니터 설치 스크립트 GCS 경로. DR 변수 변경 후 apply → 프록시 VM reset으로 반영."
  value       = "gs://${google_storage_bucket.artifact.name}/dr-monitor-install.sh"
}
