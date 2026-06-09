# [2026-06-10 박경수] 기존 수동 생성 Secrets Manager 리소스를 Terraform Cloud state로 편입
# 실제 SecretString 값은 Terraform state에 넣지 않고, secret metadata만 Terraform 관리 대상으로 편입한다.

import {
  to = aws_secretsmanager_secret.wazuh_openid_client_secret
  id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:aws-wazuh-openid-client-secret-2hnBiI"
}

import {
  to = aws_secretsmanager_secret.wazuh_dashboard_cookie_password
  id = "arn:aws:secretsmanager:ap-south-2:476293896981:secret:aws-wazuh-dashboard-cookie-password-2Hk4XR"
}
