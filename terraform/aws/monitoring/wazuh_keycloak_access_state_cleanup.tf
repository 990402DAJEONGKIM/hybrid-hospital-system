# [2026-06-10 박경수] legacy aws_security_group_rule state 정리
# 이전 apply/import 시도에서 구형 리소스가 state에 남아 있을 수 있으므로,
# 실제 AWS SG rule 삭제 없이 Terraform state에서만 제거한다.
removed {
  from = aws_security_group_rule.allow_wazuh_dashboard_to_monitoring_keycloak_http

  lifecycle {
    destroy = false
  }
}
