# 주석 처리: patient/staff TG 삭제로 불필요 by 김다정 20260604
# output "patient_tg_arn" {
#   description = "환자 포털 Target Group ARN (ECS 서비스 연결용)"
#   value       = aws_lb_target_group.patient.arn
# }
#
# output "staff_tg_arn" {
#   description = "의료진 포털 Target Group ARN (ECS 서비스 연결용)"
#   value       = aws_lb_target_group.staff.arn
# }
#
# output "patient_alb_dns" {
#   description = "환자 포털 ALB DNS 이름"
#   value       = aws_lb.patient.dns_name
# }
#
# output "patient_alb_arn" {
#   description = "환자 포털 ALB ARN"
#   value       = aws_lb.patient.arn
# }

# 통합 hospital TG ARN by 김다정 20260604
output "hospital_tg_arn" {
  description = "통합 병원 Target Group ARN (ECS hospital-service 연결용)"
  value       = aws_lb_target_group.hospital.arn
}

output "staff_alb_dns" {
  description = "통합 ALB DNS 이름 (patient/staff/admin/wazuh/grafana)"
  value       = aws_lb.staff.dns_name
}

output "staff_alb_arn" {
  description = "통합 ALB ARN"
  value       = aws_lb.staff.arn
}

output "wazuh_tg_arn" {
  description = "Wazuh 대시보드 Target Group ARN"
  value       = aws_lb_target_group.wazuh.arn
}


output "grafana_tg_arn" {
  description = "Grafana Target Group ARN"
  value       = aws_lb_target_group.aws-grafana-tg.arn
}