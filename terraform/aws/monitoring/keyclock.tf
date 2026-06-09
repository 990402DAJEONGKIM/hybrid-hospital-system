# #260609 박경수 — Keycloak SSM Parameters
# keycloak DB 비밀번호는 Secrets Manager에서 관리 (rotation.tf 참조)

# Keycloak 관리자 비밀번호 — SSM SecureString
resource "aws_ssm_parameter" "keycloak_admin_password" {
  name        = "/mzclinic/keycloak/admin_password"
  type        = "SecureString"
  value       = var.keycloak_admin_password
  description = "Keycloak admin console password"
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "keycloak_aurora_endpoint" {
  name        = "/mzclinic/keycloak/aurora_endpoint"
  type        = "String"
  value       = var.aurora_endpoint
  description = "Aurora endpoint for Keycloak DB"
}

resource "aws_ssm_parameter" "keycloak_monitoring_domain" {
  name        = "/mzclinic/keycloak/monitoring_domain"
  type        = "String"
  value       = var.monitoring_domain
  description = "Monitoring portal domain"
}

resource "aws_ssm_parameter" "keycloak_wazuh_private_ip" {
  name        = "/mzclinic/keycloak/wazuh_private_ip"
  type        = "String"
  value       = var.wazuh_private_ip
  description = "Wazuh Dashboard EC2 private IP"
}
# #260609 박경수 end
