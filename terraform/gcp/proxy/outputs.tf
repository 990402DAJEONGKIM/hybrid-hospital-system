output "proxy_internal_ip" {
  description = "HAProxy VM 내부 IP (pglogical DSN에 사용)"
  value       = data.google_compute_address.proxy_internal.address
}

output "proxy_instance_name" {
  description = "MIG base instance name"
  value       = google_compute_instance_group_manager.proxy.base_instance_name
}

output "pglogical_dsn" {
  description = "pglogical subscription DSN (Cloud SQL에서 사용)"
  value       = "host=${data.google_compute_address.proxy_internal.address} port=5433 dbname=hospital user=pglogical_repl sslmode=disable"
}