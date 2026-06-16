output "internal_nlb_dns" {
  description = "Internal NLB DNS 이름"
  value       = aws_lb.internal.dns_name
}

output "nlb_fixed_ip_2a" {
  description = "Internal NLB 고정 IP (ap-south-2a) — 클라이언트 hosts 파일 설정용"
  value       = var.nlb_ip_2a
}

output "nlb_fixed_ip_2b" {
  description = "Internal NLB 고정 IP (ap-south-2b) — 클라이언트 hosts 파일 설정용"
  value       = var.nlb_ip_2b
}

output "nlb_fixed_ip_2c" {
  description = "Internal NLB 고정 IP (ap-south-2c) — 클라이언트 hosts 파일 설정용"
  value       = var.nlb_ip_2c
}
