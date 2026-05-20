output "bastion_instance_id" {
  description = "베스천 인스턴스 ID"
  value       = var.bastion_count > 0 ? google_compute_instance.bastion[0].instance_id : null
}

output "bastion_internal_ip" {
  description = "베스천 내부 IP"
  value       = var.bastion_count > 0 ? google_compute_instance.bastion[0].network_interface[0].network_ip : null
}

output "iap_ssh_command" {
  description = "IAP SSH 접속 명령어"
  value       = var.bastion_count > 0 ? "gcloud compute ssh gcp-bastion-01 --zone=${var.zone} --tunnel-through-iap" : "bastion not running"
}
