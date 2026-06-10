# [2026-06-10 박경수] Wazuh Dashboard가 Keycloak token/jwks/userinfo endpoint를 내부망으로 호출하기 위한 SG 허용
# Wazuh Dashboard는 OIDC 로그인 완료 시 authorization code를 token으로 교환하기 위해 monitoring EC2의 nginx(:80)를 호출한다.
# source를 CIDR이 아닌 aws-wazuh-sg로 지정하여 Wazuh EC2 교체 시에도 접근 허용이 유지되도록 한다.

data "aws_security_group" "aws_wazuh_sg" {
  filter {
    name   = "group-name"
    values = ["aws-wazuh-sg"]
  }

  vpc_id = data.aws_vpc.main.id
}

# [2026-06-10 박경수] SecurityGroupRuleId 기반 신형 리소스로 SG rule을 IaC 관리
resource "aws_vpc_security_group_ingress_rule" "allow_wazuh_dashboard_to_monitoring_keycloak_http" {
  security_group_id            = aws_security_group.aws-monitoring-sg.id
  referenced_security_group_id = data.aws_security_group.aws_wazuh_sg.id

  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80

  description = "Allow Wazuh Dashboard to access Keycloak HTTP endpoints on monitoring EC2"
}
