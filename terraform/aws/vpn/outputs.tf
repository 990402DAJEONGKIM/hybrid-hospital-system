##############################################################
# outputs.tf
##############################################################

output "cgw_id" {
  description = "Customer Gateway ID"
  value       = aws_customer_gateway.main.id
}

output "vgw_id" {
  description = "Virtual Private Gateway ID"
  value       = aws_vpn_gateway.main.id
}

output "vpn_connection_id" {
  description = "VPN Connection ID"
  value       = aws_vpn_connection.main.id
}

output "tunnel1_address" {
  description = "터널1 AWS 외부 IP"
  value       = aws_vpn_connection.main.tunnel1_address
}

output "tunnel2_address" {
  description = "터널2 AWS 외부 IP"
  value       = aws_vpn_connection.main.tunnel2_address
}

output "tunnel1_psk" {
  description = "터널1 Pre-Shared Key"
  value       = aws_vpn_connection.main.tunnel1_preshared_key
  sensitive   = true
}

output "tunnel2_psk" {
  description = "터널2 Pre-Shared Key"
  value       = aws_vpn_connection.main.tunnel2_preshared_key
  sensitive   = true
}
