##############################################################
# imports.tf
# 수동 생성된 기존 리소스를 Terraform state로 가져오기
# 사용법: terraform apply (plan 단계에서 import 자동 수행)
# Terraform 1.5+ 필요
##############################################################

import {
  to = aws_customer_gateway.main
  id = "cgw-019fc2177febe2263"
}

import {
  to = aws_vpn_gateway.main
  id = "vgw-0ef8fa81db0356388"
}

import {
  to = aws_vpn_connection.main
  id = "vpn-0d0ce511ce1812582"
}

import {
  to = aws_route.pub_to_onprem
  id = "rtb-05f4ab01affbf8b28_172.30.1.0/24"
}

import {
  to = aws_route.app_to_onprem
  id = "rtb-0026d25c4d45ad41a_172.30.1.0/24"
}

import {
  to = aws_route.db_to_onprem
  id = "rtb-08dec2fa3df43ed85_172.30.1.0/24"
}
