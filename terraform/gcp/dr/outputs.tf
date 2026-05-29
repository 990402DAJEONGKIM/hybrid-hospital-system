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

output "monitor_install_script" {
  description = "프록시 VM(gcp-rds-proxy-01)에서 실행할 DR failover 모니터 설치 스크립트. apply 후 terraform output monitor_install_script 로 확인하여 프록시 VM에 붙여넣기."
  sensitive   = false
  value     = templatefile("${path.module}/scripts/startup-monitor.sh.tftpl", {
    project_id          = var.project_id
    zone                = var.zone
    mig_name            = google_compute_instance_group_manager.dr_app.name
    aws_healthcheck_url = var.aws_healthcheck_url
    interval_seconds    = var.healthcheck_interval_seconds
    failure_threshold   = var.failure_threshold
    recovery_threshold  = var.recovery_threshold
    dns_managed_zone    = var.dns_managed_zone
    dns_record_name     = var.dns_record_name
    dns_record_type     = var.dns_record_type
    dns_ttl             = var.dns_ttl
    aws_dns_rrdatas     = join(",", var.aws_dns_rrdatas)
    gcp_dns_rrdatas     = join(",", [google_compute_global_address.dr_lb.address])
    failover_mode       = var.failover_mode
    enable_ops_agent    = var.enable_ops_agent
  })
}
