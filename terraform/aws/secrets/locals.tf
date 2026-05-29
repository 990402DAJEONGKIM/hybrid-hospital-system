# =========================================================
# TC-aws-secrets — 로컬 변수
# =========================================================

locals {
  common_tags = {
    Project     = "msp-hospital"
    Environment = var.environment
    ManagedBy   = "terraform"
    Workspace   = "TC-aws-secrets"
  }

  # ── Rotation Lambda ──────────────────────────────────────
  # 실제 배포된 Lambda 이름: aws-lambda-rotation
  rotation_name      = "aws-lambda-rotation"
  rotation_role_name = "aws-lambda-rotation-role"
  rotation_ecr_name  = "aws-ecr-rotation"
  rotation_sg_name   = "aws-sg-lambda-rotation"
  rotation_cwl_name  = "/aws/lambda/aws-lambda-rotation"
}
