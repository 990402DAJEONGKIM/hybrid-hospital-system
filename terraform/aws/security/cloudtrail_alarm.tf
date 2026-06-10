locals {
  sns_arn = "arn:aws:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:aws-wazuh-cw-alerts-01"
}

# ── root 계정 사용 탐지 ──────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "aws-cw-ct-root-usage" {
  depends_on     = [aws_cloudtrail.aws-ct-01]
  name           = "RootAccountUsage"
  log_group_name = "/aws/cloudtrail/main"
  pattern        = "{ $.userIdentity.type = \"Root\" && $.eventType != \"AwsServiceEvent\" }"

  metric_transformation {
    name      = "RootAccountUsageCount"
    namespace = "CloudTrailAlarms"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-ct-root-usage" {
  alarm_name          = "ct-root-account-usage"
  alarm_description   = "root 계정 사용 탐지 - 즉시 확인 필요"
  metric_name         = "RootAccountUsageCount"
  namespace           = "CloudTrailAlarms"
  period              = 60
  evaluation_periods  = 1
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_arn]
}

# ── IAM 정책 변경 탐지 ──────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "aws-cw-ct-iam-policy-change" {
  depends_on     = [aws_cloudtrail.aws-ct-01]
  name           = "IAMPolicyChange"
  log_group_name = "/aws/cloudtrail/main"
  pattern        = "{ ($.eventName = DeleteGroupPolicy) || ($.eventName = DeleteRolePolicy) || ($.eventName = DeleteUserPolicy) || ($.eventName = PutGroupPolicy) || ($.eventName = PutRolePolicy) || ($.eventName = PutUserPolicy) || ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) || ($.eventName = AttachRolePolicy) || ($.eventName = DetachRolePolicy) }"

  metric_transformation {
    name      = "IAMPolicyChangeCount"
    namespace = "CloudTrailAlarms"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-ct-iam-policy-change" {
  alarm_name          = "ct-iam-policy-change"
  alarm_description   = "IAM 정책 변경 탐지"
  metric_name         = "IAMPolicyChangeCount"
  namespace           = "CloudTrailAlarms"
  period              = 300
  evaluation_periods  = 1
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_arn]
}

# ── 보안그룹 변경 탐지 ──────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "aws-cw-ct-sg-change" {
  depends_on     = [aws_cloudtrail.aws-ct-01]
  name           = "SecurityGroupChange"
  log_group_name = "/aws/cloudtrail/main"
  pattern        = "{ ($.eventName = AuthorizeSecurityGroupIngress) || ($.eventName = AuthorizeSecurityGroupEgress) || ($.eventName = RevokeSecurityGroupIngress) || ($.eventName = RevokeSecurityGroupEgress) || ($.eventName = CreateSecurityGroup) || ($.eventName = DeleteSecurityGroup) }"

  metric_transformation {
    name      = "SecurityGroupChangeCount"
    namespace = "CloudTrailAlarms"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-ct-sg-change" {
  alarm_name          = "ct-security-group-change"
  alarm_description   = "보안그룹 변경 탐지"
  metric_name         = "SecurityGroupChangeCount"
  namespace           = "CloudTrailAlarms"
  period              = 300
  evaluation_periods  = 1
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_arn]
}

# ── CloudTrail 비활성화 탐지 ────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "aws-cw-ct-disabled" {
  depends_on     = [aws_cloudtrail.aws-ct-01]
  name           = "CloudTrailDisabled"
  log_group_name = "/aws/cloudtrail/main"
  pattern        = "{ ($.eventName = StopLogging) || ($.eventName = DeleteTrail) || ($.eventName = UpdateTrail) }"

  metric_transformation {
    name      = "CloudTrailDisabledCount"
    namespace = "CloudTrailAlarms"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-ct-disabled" {
  alarm_name          = "ct-cloudtrail-disabled"
  alarm_description   = "CloudTrail 비활성화 시도 탐지 - 즉시 확인 필요"
  metric_name         = "CloudTrailDisabledCount"
  namespace           = "CloudTrailAlarms"
  period              = 60
  evaluation_periods  = 1
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_arn]
}

# ── 콘솔 로그인 실패 탐지 ────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "aws-cw-ct-console-login-failed" {
  depends_on     = [aws_cloudtrail.aws-ct-01]
  name           = "ConsoleLoginFailed"
  log_group_name = "/aws/cloudtrail/main"
  pattern        = "{ ($.eventName = ConsoleLogin) && ($.errorMessage = \"Failed authentication\") }"

  metric_transformation {
    name      = "ConsoleLoginFailedCount"
    namespace = "CloudTrailAlarms"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-ct-console-login-failed" {
  alarm_name          = "ct-console-login-failed"
  alarm_description   = "콘솔 로그인 실패 탐지 - ISMS-P 2.5.1"
  metric_name         = "ConsoleLoginFailedCount"
  namespace           = "CloudTrailAlarms"
  period              = 300
  evaluation_periods  = 1
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_arn]
}

# ── MFA 없는 콘솔 로그인 탐지 ───────────────────────────
resource "aws_cloudwatch_log_metric_filter" "aws-cw-ct-no-mfa-login" {
  depends_on     = [aws_cloudtrail.aws-ct-01]
  name           = "NoMFAConsoleLogin"
  log_group_name = "/aws/cloudtrail/main"
  pattern        = "{ ($.eventName = ConsoleLogin) && ($.additionalEventData.MFAUsed != \"Yes\") && ($.userIdentity.type != \"AssumedRole\") }"

  metric_transformation {
    name      = "NoMFAConsoleLoginCount"
    namespace = "CloudTrailAlarms"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-ct-no-mfa-login" {
  alarm_name          = "ct-no-mfa-console-login"
  alarm_description   = "MFA 없는 콘솔 로그인 탐지 - ISMS-P 2.5.2"
  metric_name         = "NoMFAConsoleLoginCount"
  namespace           = "CloudTrailAlarms"
  period              = 300
  evaluation_periods  = 1
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_arn]
}

# ── S3 버킷 정책 변경 탐지 ──────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "aws-cw-ct-s3-policy-change" {
  depends_on     = [aws_cloudtrail.aws-ct-01]
  name           = "S3BucketPolicyChange"
  log_group_name = "/aws/cloudtrail/main"
  pattern        = "{ ($.eventName = PutBucketPolicy) || ($.eventName = DeleteBucketPolicy) || ($.eventName = PutBucketAcl) || ($.eventName = PutBucketCors) || ($.eventName = PutBucketLifecycle) || ($.eventName = PutBucketReplication) || ($.eventName = DeleteBucketCors) || ($.eventName = DeleteBucketLifecycle) || ($.eventName = DeleteBucketReplication) }"

  metric_transformation {
    name      = "S3BucketPolicyChangeCount"
    namespace = "CloudTrailAlarms"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-ct-s3-policy-change" {
  alarm_name          = "ct-s3-bucket-policy-change"
  alarm_description   = "S3 버킷 정책 변경 탐지 - ISMS-P 2.8.1"
  metric_name         = "S3BucketPolicyChangeCount"
  namespace           = "CloudTrailAlarms"
  period              = 300
  evaluation_periods  = 1
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_arn]
}

# ── VPC 변경 탐지 ────────────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "aws-cw-ct-vpc-change" {
  depends_on     = [aws_cloudtrail.aws-ct-01]
  name           = "VPCChange"
  log_group_name = "/aws/cloudtrail/main"
  pattern        = "{ ($.eventName = CreateVpc) || ($.eventName = DeleteVpc) || ($.eventName = ModifyVpcAttribute) || ($.eventName = AcceptVpcPeeringConnection) || ($.eventName = CreateVpcPeeringConnection) || ($.eventName = DeleteVpcPeeringConnection) || ($.eventName = RejectVpcPeeringConnection) || ($.eventName = AttachClassicLinkVpc) || ($.eventName = DetachClassicLinkVpc) || ($.eventName = DisableVpcClassicLink) || ($.eventName = EnableVpcClassicLink) }"

  metric_transformation {
    name      = "VPCChangeCount"
    namespace = "CloudTrailAlarms"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "aws-cw-ct-vpc-change" {
  alarm_name          = "ct-vpc-change"
  alarm_description   = "VPC 변경 탐지 - ISMS-P 2.6.1"
  metric_name         = "VPCChangeCount"
  namespace           = "CloudTrailAlarms"
  period              = 300
  evaluation_periods  = 1
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_arn]
}