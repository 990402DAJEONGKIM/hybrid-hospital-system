output "tunnel1_address" {
  description = "터널1 AWS 외부 IP (TC-gcp-VPN-AWS aws_tunnel1_ip 변수에 입력)"
  value       = aws_vpn_connection.gcp.tunnel1_address
}

output "tunnel2_address" {
  description = "터널2 AWS 외부 IP (TC-gcp-VPN-AWS aws_tunnel2_ip 변수에 입력)"
  value       = aws_vpn_connection.gcp.tunnel2_address
}

output "vpn_connection_id" {
  description = "VPN Connection ID"
  value       = aws_vpn_connection.gcp.id
}
