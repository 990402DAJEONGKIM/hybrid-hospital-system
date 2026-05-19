output "vpc_name" {
  description = "VPC 이름 (cloud-sql workspace의 Terraform Variable로 등록)"
  value       = google_compute_network.main.name
}

output "vpc_id" {
  description = "VPC ID"
  value       = google_compute_network.main.id
}

output "subnet_name" {
  description = "서브넷 이름"
  value       = google_compute_subnetwork.db.name
}
