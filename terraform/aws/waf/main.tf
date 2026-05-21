# =========================================================
# WAF — AWS WAFv2 Web ACL
#
# patient-alb (Public):
#   2.8.3  웹 취약점 대응       → CommonRuleSet, SQLiRuleSet, KnownBadInputs
#   2.8.1  인터넷 접근 통제     → IP Reputation List
#   2.5.4  로그인 시도 제한     → Rate limiting (/auth/ 엔드포인트)
#   2.9.1  로그 관리            → WAF 로그 → CloudWatch (365일 보존)
#
# staff-alb (Public + IP 화이트리스트):
#   2.6.1  네트워크 접근통제    → 허용 IP만 통과, 나머지 차단
#   2.9.1  로그 관리            → WAF 로그 → CloudWatch (365일 보존)
# =========================================================


# ─────────────────────────────────────────────────────────
# CloudWatch Log Group — WAF 로그 (ISMS-P 2.9.1)
# WAF 로그 그룹명은 반드시 "aws-waf-logs-" 접두사 필요
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-patient-alb"
  retention_in_days = var.waf_log_retention_days
}


# ─────────────────────────────────────────────────────────
# Web ACL
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl" "patient" {
  name  = "aws-patient-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # ── Rule 1: IP 평판 목록 (알려진 악성 IP 차단) — ISMS-P 2.8.1 ──
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "IpReputationList"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 2: OWASP Top 10 공통 룰셋 — ISMS-P 2.8.3 ──────────────
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 3: SQL 인젝션 방어 — ISMS-P 2.8.3 ──────────────────────
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 4: 알려진 악성 입력값 차단 — ISMS-P 2.8.3 ─────────────
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 5: 로그인 엔드포인트 Rate Limiting — ISMS-P 2.5.4 ──────
  # /auth/ 경로에 5분당 100회 초과 요청 시 차단 (브루트포스 방어)
  rule {
    name     = "RateLimitAuthEndpoint"
    priority = 5

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_auth
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string = "/auth/"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
            positional_constraint = "STARTS_WITH"
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitAuth"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "PatientWAF"
    sampled_requests_enabled   = true
  }

  tags = {
    Name    = "aws-patient-waf"
    Purpose = "ISMS-P 2.8.1 2.8.3 2.5.4"
  }
}


# ─────────────────────────────────────────────────────────
# WAF → 환자 포털 ALB 연결
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl_association" "patient" {
  resource_arn = data.aws_lb.patient.arn
  web_acl_arn  = aws_wafv2_web_acl.patient.arn
}


# ─────────────────────────────────────────────────────────
# WAF 로그 → CloudWatch 연결 (ISMS-P 2.9.1)
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl_logging_configuration" "patient" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.patient.arn
}


# ─────────────────────────────────────────────────────────
# CloudWatch Log Group — staff WAF 로그 (ISMS-P 2.9.1)
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "waf_staff" {
  name              = "aws-waf-logs-staff-alb"
  retention_in_days = var.waf_log_retention_days
}


# ─────────────────────────────────────────────────────────
# IP Set — 허용 공인 IP 목록 (ISMS-P 2.6.1)
# 병원 공인 IP 확정 시 staff_allowed_ips 변수에 추가
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_ip_set" "staff_allowed" {
  name               = "staff-allowed-ips"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.staff_allowed_ips

  tags = {
    Name    = "staff-allowed-ips"
    Purpose = "ISMS-P 2.6.1 의료진 포털 접근 허용 IP"
  }
}


# ─────────────────────────────────────────────────────────
# Web ACL — 의료진 포털 (기본 차단, 허용 IP만 통과)
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl" "staff" {
  name  = "aws-staff-waf"
  scope = "REGIONAL"

  # 기본 동작: 차단 (허용 IP 외 모두 차단)
  default_action {
    block {}
  }

  # ── Rule 1: 허용 IP 통과 — ISMS-P 2.6.1 ────────────────
  rule {
    name     = "AllowStaffIPs"
    priority = 1

    action {
      allow {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.staff_allowed.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "StaffAllowedIPs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "StaffWAF"
    sampled_requests_enabled   = true
  }

  tags = {
    Name    = "aws-staff-waf"
    Purpose = "ISMS-P 2.6.1 의료진 포털 IP 화이트리스트"
  }
}


# ─────────────────────────────────────────────────────────
# WAF → 의료진 포털 ALB 연결
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl_association" "staff" {
  resource_arn = data.aws_lb.staff.arn
  web_acl_arn  = aws_wafv2_web_acl.staff.arn
}


# ─────────────────────────────────────────────────────────
# WAF 로그 → CloudWatch 연결 (ISMS-P 2.9.1)
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl_logging_configuration" "staff" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_staff.arn]
  resource_arn            = aws_wafv2_web_acl.staff.arn
}
