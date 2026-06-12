# =========================================================
# WAF — AWS WAFv2 Web ACL
#
# 통합 hospital-alb 1개에 WAF 1개 연결
# 수정 260612 김강환: staff → hospital 명칭 통일
#
# 룰 우선순위:
#   0. Rate limit /auth/ (전체 도메인)
#   1. IP 평판 목록 차단 (전체 도메인)
#   2. OWASP CommonRuleSet (전체 도메인)
#   3. SQL 인젝션 방어 (전체 도메인)
#   4. 알려진 악성 입력값 차단 (전체 도메인)
#   default: ALLOW (patient는 공개)
# =========================================================


# ─────────────────────────────────────────────────────────
# 주석 처리: patient WAF → patient-alb 연결 (ALB 통합으로 불필요)
# by 김다정 20260604
# ─────────────────────────────────────────────────────────
# resource "aws_wafv2_web_acl" "patient" { ... }
# resource "aws_wafv2_web_acl_association" "patient" { ... }
# resource "aws_wafv2_web_acl_logging_configuration" "aws-waf-patient-logging" { ... }
# resource "aws_kinesis_firehose_delivery_stream" "aws-firehose-waf-patient" { ... }


# staff IP Set 삭제 — 직원 포털 온프레미스 이전으로 불필요
# resource "aws_wafv2_ip_set" "staff_allowed" { ... }


# ─────────────────────────────────────────────────────────
# Web ACL — 통합 병원 WAF
# 수정 260612 김강환: staff → hospital
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl" "hospital" {
  name  = "aws-hospital-waf"
  scope = "REGIONAL"

  # 기본 동작: 허용 (patient는 공개 접근)
  default_action {
    allow {}
  }

  # ── Rule 0: 로그인 엔드포인트 Rate Limiting (전체 도메인) ────────
  # ISMS-P 2.5.4 브루트포스 방어
  rule {
    name     = "RateLimitAuthEndpoint"
    priority = 0

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

        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
        # Wazuh 대시보드 /api/check-api 오탐 차단 해제 - 260607 김강환
        rule_action_override {
          name = "EC2MetaDataSSRF_BODY"
          action_to_use {
            count {}
          }
        }
        # GenericRFI_BODY도 /api/check-api 오탐 차단 → count 전환 - 260607 김강환
        rule_action_override {
          name = "GenericRFI_BODY"
          action_to_use {
            count {}
          }
        }
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

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "HospitalWAF"
    sampled_requests_enabled   = true
  }

  tags = {
    Name    = "aws-hospital-waf"
    Purpose = "ISMS-P 2.6.1 2.8.1 2.8.3 2.5.4"
  }
}


# ─────────────────────────────────────────────────────────
# WAF → 통합 ALB 연결 (hospital-alb)
# 수정 260612 김강환: staff → hospital
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl_association" "hospital" {
  resource_arn = data.aws_lb.staff.arn
  web_acl_arn  = aws_wafv2_web_acl.hospital.arn
}


# ─────────────────────────────────────────────────────────
# WAF 로그 → Firehose → S3 (ISMS-P 2.9.1)
# 수정 260612 김강환: staff → hospital
# ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl_logging_configuration" "aws-waf-hospital-logging" {
  log_destination_configs = [
    aws_kinesis_firehose_delivery_stream.aws-firehose-waf-hospital.arn
  ]
  resource_arn = aws_wafv2_web_acl.hospital.arn

  logging_filter {
    default_behavior = "DROP"
    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"
      condition {
        action_condition {
          action = "BLOCK"
        }
      }
    }
  }
}


# ─────────────────────────────────────────────────────────
# Firehose IAM Role (ISMS-P 2.5.3 최소 권한)
# ─────────────────────────────────────────────────────────
resource "aws_iam_role" "aws-firehose-waf-role" {
  name = "aws-firehose-waf-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "aws-firehose-waf-role" }
}

resource "aws_iam_role_policy" "aws-firehose-waf-policy" {
  name = "aws-firehose-waf-policy"
  role = aws_iam_role.aws-firehose-waf-role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Write"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::aws-k2p-storage-01",
          "arn:aws:s3:::aws-k2p-storage-01/*"
        ]
      },
      {
        Sid    = "KMSEncrypt"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.terraform_remote_state.aws-kms.outputs.s3_kms_key_arn
      }
    ]
  })
}

# 주석 처리: patient WAF Firehose 삭제 by 김다정 20260604
# resource "aws_kinesis_firehose_delivery_stream" "aws-firehose-waf-patient" {
#   name        = "aws-waf-logs-patient"
#   destination = "extended_s3"
#   extended_s3_configuration {
#     role_arn            = aws_iam_role.aws-firehose-waf-role.arn
#     bucket_arn          = "arn:aws:s3:::aws-k2p-storage-01"
#     prefix              = "waf/patient/"
#     error_output_prefix = "waf/patient/errors/"
#     buffering_size      = 5
#     buffering_interval  = 300
#     kms_key_arn         = data.terraform_remote_state.aws-kms.outputs.s3_kms_key_arn
#   }
#   tags = { Name = "aws-firehose-waf-patient" }
# }

# 수정 260612 김강환: staff → hospital
resource "aws_kinesis_firehose_delivery_stream" "aws-firehose-waf-hospital" {
  name        = "aws-waf-logs-hospital"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.aws-firehose-waf-role.arn
    bucket_arn          = "arn:aws:s3:::aws-k2p-storage-01"
    prefix              = "waf/hospital/"
    error_output_prefix = "waf/hospital/errors/"
    buffering_size      = 5
    buffering_interval  = 300
    kms_key_arn         = data.terraform_remote_state.aws-kms.outputs.s3_kms_key_arn
  }

  tags = { Name = "aws-firehose-waf-hospital" }
}
