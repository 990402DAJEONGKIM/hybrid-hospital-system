output "gcp_vpn_ip" {
  description = "GCP VPN Gateway 외부 IP (TC-aws-VPN-GCP gcp_vpn_ip 변수에 입력)"
  value       = google_compute_address.vpn_ip.address
}

output "tunnel1_status" {
  description = "터널1 상태"
  value       = google_compute_vpn_tunnel.tunnel1.detailed_status
}

output "tunnel2_status" {
  description = "터널2 상태"
  value       = google_compute_vpn_tunnel.tunnel2.detailed_status
}
