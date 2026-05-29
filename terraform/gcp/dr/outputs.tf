output "dr_lb_ip" {
  description = "GCP DR 예약 서비스 외부 LB IP"
  value       = google_compute_global_address.dr_lb.address
}

output "dr_mig_name" {
  description = "DR 앱 Managed Instance Group 이름"
  value       = google_compute_instance_group_manager.dr_app.name
}

output "monitor_instance" {
  description = "AWS healthcheck 모니터 VM 이름"
  value       = google_compute_instance.monitor.name
}

output "artifact_bucket" {
  description = "DR 앱 아티팩트 버킷"
  value       = google_storage_bucket.artifact.name
}
