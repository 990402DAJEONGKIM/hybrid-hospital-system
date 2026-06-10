# [2026-06-10 박경수] 이미 AWS에 존재하는 Wazuh → Monitoring tcp/80 SG rule을 Terraform state로 가져오기 위한 import block
# Import 완료 후 별도 PR에서 제거 가능

import {
  to = aws_security_group_rule.allow_wazuh_dashboard_to_monitoring_keycloak_http
  id = "sg-0ffb3c639be6e59b2_ingress_tcp_80_80_sg-0e75baea0d53bc77b"
}
