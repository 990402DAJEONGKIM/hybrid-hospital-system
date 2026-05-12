# =============================================================
# Terraform Import 블록
# 콘솔에서 생성한 리소스를 Terraform state로 가져오기
#
# 실행 순서:
#   1. terraform init
#   2. terraform plan   ← import 블록 자동 인식
#   3. terraform apply  ← state 등록
#   4. terraform plan   ← No changes 확인
# =============================================================

# ── 보안 그룹 ─────────────────────────────────────────────────
import {
  to = aws_security_group.proxy
  id = "sg-069b8b11e4dfd439a"   # aws-proxy-sg
}

import {
  to = aws_security_group.rds
  id = "sg-09f6c3596fb691e55"   # aws-rds-sg
}

# ── DB 서브넷 그룹 ────────────────────────────────────────────
import {
  to = aws_db_subnet_group.main
  id = "aws-db-subnet-group-01"
}

# ── Aurora 클러스터 ───────────────────────────────────────────
import {
  to = aws_rds_cluster.main
  id = "aws-aurora-01"
}

# ── Writer 인스턴스 ───────────────────────────────────────────
import {
  to = aws_rds_cluster_instance.writer
  id = "aws-aurora-01-instance-1-ap-south-2a"
}

# ── IAM Role — Enhanced Monitoring ───────────────────────────
import {
  to = aws_iam_role.enhanced_monitoring
  id = "aws-rds-monitoring-role"
}

# ── IAM Role — RDS Proxy ──────────────────────────────────────
import {
  to = aws_iam_role.rds_proxy
  id = "aws-rds-proxy-role"
}

# ── RDS Proxy ─────────────────────────────────────────────────
# import {
#   to = aws_db_proxy.main
#   id = "aws-rds-proxy-01"
# }
