output "proxy_internal_ip" {
  description = "HAProxy VM 내부 IP (pglogical DSN에 사용)"
  value       = var.proxy_count > 0 ? google_compute_instance.proxy[0].network_interface[0].network_ip : null
}

output "proxy_instance_name" {
  description = "프록시 인스턴스 이름"
  value       = var.proxy_count > 0 ? google_compute_instance.proxy[0].name : null
}

output "pglogical_dsn" {
  description = "pglogical subscription DSN (Cloud SQL에서 사용)"
  value       = var.proxy_count > 0 ? "host=${google_compute_instance.proxy[0].network_interface[0].network_ip} port=5433 dbname=hospital user=pglogical_repl sslmode=disable" : null
}
