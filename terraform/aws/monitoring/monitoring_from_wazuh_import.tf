# [2026-06-10 박경수] 이미 AWS에 존재하는 Wazuh Dashboard → Monitoring Keycloak HTTP SG rule을 Terraform state로 가져오기 위한 import block
# 대상 리소스는 기존 main.tf의 aws_security_group_rule.monitoring_from_wazuh 이다.
# Import 완료 후 별도 PR에서 제거 가능.

import {
  to = aws_security_group_rule.monitoring_from_wazuh
  id = "sg-0ffb3c639be6e59b2_ingress_tcp_80_80_sg-0e75baea0d53bc77b"
}
